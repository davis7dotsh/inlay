import AppKit
import Combine
import Darwin
import Observation
import TranscriberCore
import ServiceManagement
import SwiftUI

@main
@MainActor
enum TranscriberApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: TranscriberBuild.current.bundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing {
            existing.activate(options: [.activateAllWindows])
            return
        }
        app.setActivationPolicy(.accessory)
        let delegate = TranscriberAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class TranscriberAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controller: TranscriberController!
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var popover: NSPopover!
    private var menuContent: NSHostingController<TranscriberMenuView>!
    private var hud: DictationPanel!
    private var activitySubscription: AnyCancellable?
    private var configuration: ConfigurationStore?
    private var startupTask: Task<Void, Never>?
    private var reopenRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refuse retired names before loading settings: ignoring them would point a test build at real data.
        let retired = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("V07_") }.sorted()
        guard retired.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Rename the old environment variables"
            alert.informativeText = "\(retired.joined(separator: ", ")) use the retired V07_ prefix. Rename them to TRANSCRIBER_. No settings were loaded and no server was contacted."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let root = ProcessInfo.processInfo.environment["TRANSCRIBER_CLIENT_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TranscriberBuild.current.dataDirectory
        let configuration = ConfigurationStore(
            file: ConfigurationFile(url: root.appendingPathComponent("config.json"))
        )
        self.configuration = configuration
        startupTask = Task {
            // Load the file before installing a hotkey or using any preference.
            await configuration.start()
            guard !Task.isCancelled else { return }
            finishLaunching(configuration: configuration)
            startupTask = nil
        }
    }

    private func finishLaunching(configuration: ConfigurationStore) {
        controller = TranscriberController(configuration: configuration)
        hud = DictationPanel(controller: controller)
        controller.onShowWindow = { [weak self] in self?.showWindow() }
        controller.onHUDVisibility = { [weak self] visible in
            if visible { self?.hud.present() }
            else { self?.hud.dismiss() }
        }
        configureApplicationMenu()
        configureStatusItem()
        let defaults = UserDefaults.standard
        if reopenRequested || configuration.errorMessage != nil || !defaults.bool(forKey: "hasLaunched") || !controller.allPermissionsGranted {
            showWindow()
        }
        defaults.set(true, forKey: "hasLaunched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        configuration?.stopWatching()
        controller?.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        configuration?.stopWatching()
        controller?.shutdown()
        guard startupTask != nil || (configuration?.pendingWriteCount ?? 0) > 0 else { return .terminateNow }
        startupTask?.cancel()
        Task {
            await startupTask?.value
            configuration?.stopWatching()
            await configuration?.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func showWindow() {
        guard controller != nil else { reopenRequested = true; return }
        popover?.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.title = TranscriberBuild.current.displayName
            // Let native chrome obscure scrolling form content under the title.
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .automatic
            window.backgroundColor = NSColor(TranscriberPalette.canvas)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 620)
            window.contentViewController = NSHostingController(rootView: TranscriberWindowView(controller: controller))
            window.delegate = self
            if !window.setFrameUsingName(TranscriberBuild.current.windowAutosaveName) { window.center() }
            window.setFrameAutosaveName(TranscriberBuild.current.windowAutosaveName)
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        controller.refreshPermissions()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            controller.refreshPermissions()
            // Settle SwiftUI's height before AppKit chooses the on-screen frame.
            // Late hosting-view resizing can otherwise grow the popover upwards.
            let fitted = menuContent.sizeThatFits(in: NSSize(
                width: TranscriberMenuView.width, height: .greatestFiniteMagnitude
            ))
            let size = NSSize(width: ceil(fitted.width), height: ceil(fitted.height))
            menuContent.preferredContentSize = size
            menuContent.view.setFrameSize(size)
            popover.contentSize = size
            menuContent.view.layoutSubtreeIfNeeded()
            let bottomEdge: NSRectEdge = button.isFlipped ? .maxY : .minY
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: bottomEdge)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func configureStatusItem() {
        // Keep the slot present while swapping artwork; a status transition
        // must never depend on the new image's intrinsic width.
        statusItem = NSStatusBar.system.statusItem(withLength: TranscriberBuild.current.isDevelopment ? 62 : 30)
        if let button = statusItem.button {
            TranscriberBrand.updateStatusButton(button, activity: controller.activity, shortcuts: controller.shortcuts,
                                         activationMode: controller.activationMode)
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover = NSPopover()
        popover.behavior = .transient
        menuContent = NSHostingController(rootView: TranscriberMenuView(
            controller: controller, openWindow: { [weak self] in self?.showWindow() },
            quit: { NSApp.terminate(nil) }
        ))
        // This compact menu has bounded status/preview slots. Keep its frame
        // stable while open, and remeasure current content on the next opening.
        menuContent.sizingOptions = []
        popover.contentViewController = menuContent
        activitySubscription = controller.$activity.combineLatest(controller.$shortcuts, controller.$activationMode)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
            .sink { [weak self] activity, shortcuts, activationMode in
            guard let button = self?.statusItem.button else { return }
            TranscriberBrand.updateStatusButton(button, activity: activity, shortcuts: shortcuts, activationMode: activationMode)
        }
    }

    private func configureApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let show = NSMenuItem(title: "Open \(TranscriberBuild.current.displayName)", action: #selector(showWindow), keyEquivalent: ",")
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(TranscriberBuild.current.displayName)", action: #selector(self.quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

enum DictationPanelLayout {
    static var contentSize: NSSize {
        NSSize(width: DictationHUD.width + 36, height: DictationHUD.height + DictationHUD.noticeHeight + 36)
    }

    static func windowFrame(from frame: NSRect, showsNotice: Bool, compact: Bool = false) -> NSRect {
        let height = contentSize.height - (showsNotice ? 0 : DictationHUD.noticeHeight)
        let width = compact && !showsNotice ? DictationHUD.height + 36 : contentSize.width
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }

    static func contentFrame(in windowSize: NSSize) -> NSRect {
        NSRect(x: (windowSize.width - contentSize.width) / 2, y: windowSize.height - contentSize.height,
               width: contentSize.width, height: contentSize.height)
    }
}

private final class DictationPanel: NSPanel {
    private let hostedHUD: NSView
    private let presentation = DictationHUDPresentation()
    private var activitySubscription: AnyCancellable?
    private var compactTask: Task<Void, Never>?
    private var activity: DictationActivity = .idle
    private var showsNotice = false
    private var compact = false

    init(controller: TranscriberController) {
        let hostingView = NSHostingView(rootView: DictationHUD(controller: controller, presentation: presentation).padding(18))
        hostingView.sizingOptions = []
        hostedHUD = hostingView
        let initialFrame = DictationPanelLayout.windowFrame(
            from: NSRect(origin: .zero, size: DictationPanelLayout.contentSize), showsNotice: false
        )
        super.init(contentRect: initialFrame,
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        // Join other apps' Stage Manager sets and full-screen spaces without
        // activating Transcriber or taking keyboard focus from the insertion target.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let container = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        contentView = container
        container.addSubview(hostedHUD)
        hostedHUD.frame = DictationPanelLayout.contentFrame(in: frame.size)
        trackNotice(controller.recordingFeedback)
        activitySubscription = controller.$activity.removeDuplicates().sink { [weak self] activity in
            self?.activity = activity
            self?.updateCompactState()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Size the window from the same notice the HUD draws. Observation fires
    /// before the change lands, so read the new value on the next main-actor turn.
    private func trackNotice(_ feedback: RecordingFeedback) {
        let visible = withObservationTracking { feedback.limitNotice != nil } onChange: { [weak self] in
            Task { @MainActor in self?.trackNotice(feedback) }
        }
        setNoticeVisible(visible)
    }

    private func setNoticeVisible(_ visible: Bool) {
        guard visible != showsNotice else { return }
        showsNotice = visible
        // Only extend the native hit area while the notice is visible. Keep
        // the hosted content anchored to the top so the capsule never moves.
        updateFrame()
    }

    private func updateFrame() {
        setFrame(DictationPanelLayout.windowFrame(from: frame, showsNotice: showsNotice, compact: compact), display: false)
        hostedHUD.frame = DictationPanelLayout.contentFrame(in: frame.size)
    }

    private func updateCompactState() {
        compactTask?.cancel()
        if activity.isBusy {
            compact = false
            updateFrame()
        } else {
            compactTask = Task { [weak self] in
                // Let the visual finish contracting before trimming the native
                // window, so its invisible sides no longer intercept clicks.
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    do { try await Task.sleep(for: .seconds(DictationHUD.morphDuration + 0.04)) }
                    catch { return }
                }
                guard let self, !Task.isCancelled, presentation.id != nil else { return }
                compact = true
                updateFrame()
            }
        }
    }

    func dismiss() {
        compactTask?.cancel()
        presentation.id = nil
        orderOut(nil)
    }

    func present() {
        compact = false
        updateFrame()
        presentation.id = UUID()
        updateCompactState()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let noticeOffset = showsNotice ? DictationHUD.noticeHeight : 0
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 20 - noticeOffset))
        }
        orderFrontRegardless()
    }
}

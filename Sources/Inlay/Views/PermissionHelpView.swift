import InlayCore
import AppKit
import SwiftUI

struct PermissionHelpButton: View {
    @State private var showingHelp = false

    var body: some View {
        Button("Not listed in System Settings?") { showingHelp = true }
            .buttonStyle(InlayQuietButtonStyle())
            .accessibilityIdentifier("permissions.manual-help")
            .sheet(isPresented: $showingHelp) { PermissionHelpView() }
    }
}

private struct PermissionHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private var paneTitle: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access" : "Accessibility"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add \(InlayBuild.current.displayName) to Accessibility")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(InlayPalette.ink)

            Text("In System Settings → Privacy & Security → \(paneTitle), click +. Press ⌘⇧G and use this path, then click Open and turn \(InlayBuild.current.displayName) on.")
                .font(.system(size: 13))
                .foregroundStyle(InlayPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    InlayMark(color: InlayPalette.accent, size: 23)
                    Text(Bundle.main.bundleURL.lastPathComponent)
                        .font(.system(size: 16, weight: .medium))
                }
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                    .help("You can also drag \(InlayBuild.current.displayName) into the Accessibility list.")
                Text(Bundle.main.bundleURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InlayPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("Accessibility also enables the dictation key. You do not need a separate Input Monitoring grant.")
                .font(.system(size: 12))
                .foregroundStyle(InlayPalette.muted)

            Text("Already listed but still blocked? Remove the \(InlayBuild.current.displayName) entry with −, add this copy again, then quit and reopen \(InlayBuild.current.displayName).")
                .font(.system(size: 12))
                .foregroundStyle(InlayPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Open privacy settings") { PermissionManager.openAccessibilitySettings() }
                    .buttonStyle(InlayPrimaryButtonStyle())
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(InlayPrimaryButtonStyle(prominent: false))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 580)
        .background(InlayPalette.canvas)
    }
}

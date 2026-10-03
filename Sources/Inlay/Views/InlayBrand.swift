import InlayCore
import AppKit
import SwiftUI

/// Three fitted strokes form an inset I, matching Resources/Inlay.svg.
enum InlayBrand {
    static func logoPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let strokes = [
            CGRect(x: 20, y: 20, width: 88, height: 16),
            CGRect(x: 56, y: 44, width: 16, height: 40),
            CGRect(x: 20, y: 92, width: 88, height: 16),
        ]
        for stroke in strokes {
            path.addRoundedRect(in: stroke, cornerWidth: 8, cornerHeight: 8)
        }
        var transform = CGAffineTransform(a: rect.width / 128, b: 0, c: 0, d: rect.height / 128,
                                         tx: rect.minX, ty: rect.minY)
        return path.copy(using: &transform) ?? path
    }

    private static let restingStatusImage = makeStatusLogo()
    private static let recordingStatusImage = makeStatusSymbol("waveform", description: "\(InlayBuild.current.displayName) — listening")
    private static let processingStatusImage = makeStatusSymbol("ellipsis", description: "\(InlayBuild.current.displayName) — processing")

    static func statusImage(for activity: DictationActivity = .idle) -> NSImage {
        switch activity {
        case .starting, .recording: recordingStatusImage
        case .transcribing, .delivering: processingStatusImage
        case .idle, .success, .failed: restingStatusImage
        }
    }

    /// Status-bar templates must let AppKit choose their foreground. In
    /// particular, do not bridge the SwiftUI brand tint onto NSStatusBarButton.
    static func updateStatusButton(_ button: NSButton, activity: DictationActivity, shortcut: HoldKey,
                                   activationMode: HotkeyActivationMode = .hold) {
        button.contentTintColor = nil
        button.imagePosition = .imageLeading
        button.title = InlayBuild.current.isDevelopment ? " Dev" : ""
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.imageScaling = .scaleProportionallyDown
        button.image = statusImage(for: activity)
        let description: String
        switch activity {
        case .starting: description = "\(InlayBuild.current.displayName) — starting microphone"
        case .recording: description = "\(InlayBuild.current.displayName) — listening"
        case .transcribing: description = "\(InlayBuild.current.displayName) — transcribing"
        case .delivering: description = "\(InlayBuild.current.displayName) — delivering your words"
        case .failed: description = "\(InlayBuild.current.displayName) — dictation needs attention"
        case .idle, .success:
            let verb = activationMode == .doubleTapToggle ? "double tap" : "hold"
            description = "\(InlayBuild.current.displayName) — \(verb) \(shortcut.title) to dictate"
        }
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private static func makeStatusSymbol(_ name: String, description: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) else {
            return restingStatusImage
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    /// Use the same inset I mark as the app, with native menu-bar contrast.
    private static func makeStatusLogo() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(logoPath(in: rect))
            context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(InlayBuild.current.displayName)"
        return image
    }
}

struct InlayLogo: Shape {
    func path(in rect: CGRect) -> Path { Path(InlayBrand.logoPath(in: rect)) }
}

/// The warm app tile stays consistent with the Dock icon in either appearance.
struct InlayAppIcon: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.21875, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 252 / 255, green: 249 / 255, blue: 242 / 255),
                                              Color(red: 232 / 255, green: 217 / 255, blue: 212 / 255)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.21875, style: .continuous)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 0.5)
                }
                .padding(size * 12 / 512)
            InlayLogo()
                .fill(Color(red: 53 / 255, green: 45 / 255, blue: 58 / 255))
                .frame(width: size * 0.675, height: size * 0.675)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

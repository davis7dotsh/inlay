import TranscriberCore
import AppKit
import SwiftUI

/// Seven signal strokes form a V, matching Resources/Transcriber.svg.
enum TranscriberBrand {
    static func logoPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let strokes: [(CGFloat, CGFloat, CGFloat)] = [
            (16, 27, 27), (32, 39, 28), (48, 51, 30), (64, 64, 36),
            (80, 51, 30), (96, 39, 28), (112, 27, 27),
        ]
        for (x, y, length) in strokes {
            path.addRoundedRect(in: CGRect(x: x - 5, y: y - 5, width: 10, height: length + 10),
                                cornerWidth: 5, cornerHeight: 5)
        }
        var transform = CGAffineTransform(a: rect.width / 128, b: 0, c: 0, d: rect.height / 128,
                                         tx: rect.minX, ty: rect.minY)
        return path.copy(using: &transform) ?? path
    }

    private static let restingStatusImage = makeStatusLogo()
    private static let recordingStatusImage = makeStatusSymbol("waveform", description: "\(TranscriberBuild.current.displayName) — listening")
    private static let processingStatusImage = makeStatusSymbol("ellipsis", description: "\(TranscriberBuild.current.displayName) — processing")

    static func statusImage(for activity: DictationActivity = .idle) -> NSImage {
        switch activity {
        case .starting, .recording: recordingStatusImage
        case .transcribing, .delivering: processingStatusImage
        case .idle, .success, .failed: restingStatusImage
        }
    }

    /// Status-bar templates must let AppKit choose their foreground. In
    /// particular, do not bridge the SwiftUI brand tint onto NSStatusBarButton.
    static func updateStatusButton(_ button: NSButton, activity: DictationActivity, shortcuts: [HoldKey],
                                   activationMode: HotkeyActivationMode = .hold) {
        button.contentTintColor = nil
        button.imagePosition = .imageLeading
        button.title = TranscriberBuild.current.isDevelopment ? " Dev" : ""
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.imageScaling = .scaleProportionallyDown
        button.image = statusImage(for: activity)
        let description: String
        switch activity {
        case .starting: description = "\(TranscriberBuild.current.displayName) — starting microphone"
        case .recording: description = "\(TranscriberBuild.current.displayName) — listening"
        case .transcribing: description = "\(TranscriberBuild.current.displayName) — transcribing"
        case .delivering: description = "\(TranscriberBuild.current.displayName) — delivering your words"
        case .failed: description = "\(TranscriberBuild.current.displayName) — dictation needs attention"
        case .idle, .success:
            let keys = shortcuts.map(\.title).orList
            let action = switch activationMode {
            case .hold: "hold \(keys) to dictate"
            case .doubleTapToggle: "double tap \(keys) to dictate"
            case .singleTapToggle: "press \(keys) to start or stop dictation"
            }
            description = "\(TranscriberBuild.current.displayName) — \(action)"
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

    /// Use the same seven-stroke mark as the app, with native menu-bar contrast.
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
        image.accessibilityDescription = "\(TranscriberBuild.current.displayName)"
        return image
    }
}

struct TranscriberLogo: Shape {
    func path(in rect: CGRect) -> Path { Path(TranscriberBrand.logoPath(in: rect)) }
}

/// The warm app tile stays consistent with the Dock icon in either appearance.
struct TranscriberAppIcon: View {
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
            TranscriberLogo()
                .fill(Color(red: 53 / 255, green: 45 / 255, blue: 58 / 255))
                .frame(width: size * 0.675, height: size * 0.675)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

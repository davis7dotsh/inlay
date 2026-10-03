import AppKit
import SwiftUI

enum InlayPalette {
    // Glacier is the dark counterpart to Inlay's unchanged warm light palette.
    static let ink = adaptive(light: 0x352D3A, dark: 0xEDF5FA, contrastLight: 0x241E28, contrastDark: 0xFFFFFF)
    static let muted = adaptive(light: 0x766D78, dark: 0xA4B8C7, contrastLight: 0x514955, contrastDark: 0xDAEAF5)
    static let faint = muted
    static let canvas = adaptive(light: 0xF8F6F2, dark: 0x1B252E)
    // Opaque equivalents of the mockup's raised glass layers keep long text legible.
    static let surface = adaptive(light: 0xFFFDF9, dark: 0x222C35)
    static let sidebar = adaptive(light: 0xEDE8E4, dark: 0x2B3E4D)
    static let tint = adaptive(light: 0xEEE2DE, dark: 0xB2DFFF, darkAlpha: 0.08, contrastDark: 0x3A5265)
    static let line = adaptive(light: 0xE5DFE1, dark: 0x485B6B, contrastLight: 0x8F8190, contrastDark: 0xA6C1D5)
    static let accent = adaptive(light: 0xC5513E, dark: 0xA7D6F5, contrastLight: 0xA93F2F, contrastDark: 0xD2ECFF)
    /// A slightly deeper light-appearance vermilion keeps small text legible.
    static let accentInk = adaptive(light: 0xB44634, dark: 0xA7D6F5, contrastLight: 0x963325, contrastDark: 0xD2ECFF)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x192C3A)
    static let glassTint = adaptive(light: 0xF8F6F2, dark: 0x223949)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)

    private static func adaptive(light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1,
                                 contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,
                                                     .accessibilityHighContrastAqua, .darkAqua, .aqua]) ?? .aqua
            let value: UInt32
            switch match {
            case .accessibilityHighContrastDarkAqua: value = contrastDark ?? dark
            case .accessibilityHighContrastAqua: value = contrastLight ?? light
            case .darkAqua: value = dark
            default: value = light
            }
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: match == .darkAqua ? darkAlpha : 1)
        })
    }
}

/// Only the sidebar looks through the window; reading and editing surfaces stay
/// solid. Use AppKit's behind-window material rather than blurring app content.
struct InlaySidebarSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if colorScheme == .dark && !reduceTransparency && contrast != .increased {
            InlaySidebarMaterial()
                .overlay(InlayPalette.sidebar.opacity(0.54))
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.05), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            InlayPalette.sidebar
        }
    }
}

private struct InlaySidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// NSPopover already provides the native glass. Give its contents a quiet slate
/// tint without adding a second glass container, corner, or hit-testing layer.
struct InlayMenuSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if colorScheme == .dark {
            if reduceTransparency || contrast == .increased {
                InlayPalette.surface
            } else {
                InlayPalette.glassTint.opacity(0.71)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0.07), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
            }
        } else {
            Color.clear
        }
    }
}

struct InlayMark: View {
    var color: Color = InlayPalette.ink
    var size: CGFloat = 26

    var body: some View {
        InlayLogo()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Delegate interaction, focus, disabled states, and sizing to the system styles.
struct InlayPrimaryButtonStyle: PrimitiveButtonStyle {
    var prominent = true

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(configuration)
                .buttonStyle(.borderedProminent)
                .foregroundStyle(InlayPalette.onAccent)
                .controlSize(.regular)
        } else {
            Button(configuration)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }
}

struct InlayQuietButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderless)
            .controlSize(.regular)
    }
}

/// A consistent label and hit area for compact, icon-only settings actions.
struct InlayControlIcon: View {
    var systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

/// A grouped settings surface for content that needs a flexible, non-Form layout.
struct InlaySettingsGroup<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .background {
                shape.fill(InlayPalette.surface)
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(InlayPalette.line, lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

struct SettingsIcon: View {
    var symbol: String
    var color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Glass belongs to floating controls, not the transcript or settings content.
struct InlayFloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(InlayPalette.surface, in: shape)
                .overlay { shape.strokeBorder(InlayPalette.ink.opacity(0.35), lineWidth: 1) }
        } else if #available(macOS 26.0, *) {
            if colorScheme == .dark {
                // Keep the live logo/meter/clock outside the compositor's glass
                // layer. A tinted glass effect on the entire HUD can drop all
                // foreground drawing on newer macOS renderers.
                content.background {
                    shape.fill(InlayPalette.glassTint.opacity(0.5))
                        .glassEffect(.regular, in: shape)
                        .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                }
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background {
                    if colorScheme == .dark { shape.fill(InlayPalette.glassTint.opacity(0.55)) }
                }
                .overlay { shape.strokeBorder(InlayPalette.line, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.15), radius: 14, y: 5)
        }
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MicrophoneTestLabel: View {
    var inputName: String
    var isCapturing: Bool
    var isHeldFn = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isHeldFn ? "waveform" : (isCapturing ? "stop.fill" : "mic"))
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(InlayPalette.accentInk)
            Text(isHeldFn ? "Release fn to finish" : inputName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
            Image(systemName: isHeldFn ? "arrow.up" : (isCapturing ? "checkmark" : "play.fill"))
                .font(.system(size: 10, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(InlayPalette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHeldFn ? "Release fn to finish" : (isCapturing ? "Finish dictation" : "Test \(inputName)"))
    }
}

struct KeyCap: View {
    var key: HoldKey
    var isPressed = false

    var body: some View {
        HStack(spacing: 7) {
            Text(key.symbol)
                .font(.system(size: 15, weight: .medium))
            if key != .fn {
                Text(key.title)
                    .font(.callout)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isPressed ? InlayPalette.accentInk : InlayPalette.muted)
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isPressed ? InlayPalette.tint : InlayPalette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isPressed ? InlayPalette.accentInk : InlayPalette.line, lineWidth: 0.5)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.title)
        .accessibilityValue(isPressed ? "Pressed" : "Not pressed")
    }
}

struct InlayHoldKeyCap: View {
    var key: HoldKey
    var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(InlayPalette.line)
                .frame(height: 60)
                .offset(y: 4)
            Text(key.symbol)
                .font(.system(size: key == .fn ? 27 : 30, weight: .regular))
                .foregroundStyle(InlayPalette.accentInk)
                .frame(width: 64, height: 60)
                .background(isPressed ? InlayPalette.tint : InlayPalette.surface, in: shape)
                .overlay { shape.strokeBorder(InlayPalette.line, lineWidth: contrast == .increased ? 1.5 : 0.7) }
                .offset(y: isPressed ? 3 : 0)
        }
        .frame(width: 64, height: 64)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.title)
        .accessibilityValue(isPressed ? "Pressed" : "Not pressed")
    }
}

struct LiveWaveform: View {
    var levels: [Float]
    var color: Color = InlayPalette.accent
    var height: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var barHeights: [CGFloat] {
        let recent = Array(levels.suffix(9))
        let history = Array(repeating: Float(0), count: 9 - recent.count) + recent
        return history.map { level in
            let normalized = level.isFinite ? min(1, max(0, level)) : 0
            return 3 + max(0, height - 3) * CGFloat(normalized)
        }
    }

    var body: some View {
        let heights = barHeights
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: heights[index])
            }
        }
        .frame(width: 51, height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: heights)
        .accessibilityHidden(true)
    }
}

struct RecordingWaveform: View {
    @ObservedObject var feedback: RecordingFeedback
    var color: Color = InlayPalette.accent
    var height: CGFloat = 28

    var body: some View {
        LiveWaveform(levels: feedback.levels, color: color, height: height)
    }
}

/// A clock subscribes to whole seconds, not the meter's twenty samples/second.
struct RecordingElapsedTime: View {
    let feedback: RecordingFeedback
    @State private var seconds = 0

    var body: some View {
        Text(inlayDuration(Double(seconds)))
            .monospacedDigit()
            .frame(minWidth: 34, alignment: .trailing)
            .onReceive(feedback.$elapsedSeconds.removeDuplicates()) { seconds = $0 }
            .accessibilityLabel("Recording time")
            .accessibilityValue(inlayDuration(Double(seconds)))
    }
}

struct InlayRule: View {
    var body: some View {
        Divider()
            .accessibilityHidden(true)
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var reviewGranted = false
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(InlayPalette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(InlayPalette.muted)
            }

            Spacer(minLength: 10)

            if granted {
                HStack(spacing: 8) {
                    Text("Allowed")
                        .foregroundStyle(.secondary)
                    if reviewGranted {
                        Button(action: action) {
                            InlayControlIcon(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Open \(title) settings")
                        .accessibilityLabel("\(title) allowed. Open settings.")
                    }
                }
            } else {
                Button("Allow", action: action)
                    .buttonStyle(InlayPrimaryButtonStyle(prominent: false))
                    .accessibilityLabel("Allow \(title)")
            }
        }
        .frame(minHeight: 45)
    }
}

struct InlineNotice: View {
    var message: String
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 13))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isError ? InlayPalette.warning : InlayPalette.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((isError ? InlayPalette.warning : InlayPalette.muted).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

func inlayDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Reserve the action-feedback slot so an error never moves the controls below it.
struct InlayActionMessage: View {
    var message: String?

    var body: some View {
        Text(message ?? "")
            .font(.caption)
            .foregroundStyle(InlayPalette.warning)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32, alignment: .topLeading)
            .help(message ?? "")
            .accessibilityHidden(message == nil)
    }
}

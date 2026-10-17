import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hidsystem

struct PermissionSnapshot: Equatable, Sendable {
    let microphone: Bool
    let accessibility: Bool
    let inputMonitoring: Bool

    // Accessibility already grants event listening as well as insertion. A
    // separate Input Monitoring grant is only needed without Accessibility.
    var canListenForHotkey: Bool { accessibility || inputMonitoring }

    static func capture() -> Self {
        Self(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }
}

@MainActor
enum PermissionManager {
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            openMicrophoneSettings()
            return false
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestInputMonitoring() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            openInputMonitoringSettings()
        }
    }

    static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

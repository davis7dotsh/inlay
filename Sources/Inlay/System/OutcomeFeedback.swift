import AppKit

/// VoiceOver announcements and short outcome sounds. Announcements are always
/// posted (macOS speaks them only while VoiceOver runs); sounds honor the
/// dictation-sounds preference.
@MainActor
enum OutcomeFeedback {
    enum Sound {
        case start, success, attention, failure

        fileprivate var systemName: String {
            switch self {
            case .start: "Tink"
            case .success: "Pop"
            case .attention: "Purr"
            case .failure: "Basso"
            }
        }
    }

    private static var sounds: [Sound: NSSound] = [:]

    static func announce(_ message: String, sound: Sound?, soundsEnabled: Bool) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
        guard soundsEnabled, let sound else { return }
        let player = sounds[sound] ?? NSSound(named: NSSound.Name(sound.systemName))
        guard let player else { return }
        sounds[sound] = player
        if player.isPlaying { player.stop() }
        player.play()
    }
}

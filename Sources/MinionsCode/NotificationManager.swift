import AppKit
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var lastStatuses: [String: String] = [:]
    private var hasRequestedPermission = false

    func ensurePermission() {
        guard !hasRequestedPermission else { return }
        hasRequestedPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func observe(sessions: [SessionInfo]) {
        let settings = AppSettings.shared
        guard settings.notificationsEnabled else {
            // Still update tracker so we don't fire a backlog if user toggles back on
            lastStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })
            return
        }

        for session in sessions {
            let prev = lastStatuses[session.id]
            let curr = session.status

            // Detect transition: busy → idle (Claude just finished a turn)
            if prev == "busy" && curr == "idle" && session.isAlive {
                fireCompletion(session: session)
            }

            lastStatuses[session.id] = curr
        }

        // Cleanup dead sessions from tracker
        let alive = Set(sessions.map(\.id))
        lastStatuses = lastStatuses.filter { alive.contains($0.key) }
    }

    private func fireCompletion(session: SessionInfo) {
        let settings = AppSettings.shared

        let content = UNMutableNotificationContent()
        content.title = "Claude finished"
        content.body = session.name
        if settings.soundEnabled {
            content.sound = .default
        }

        let request = UNNotificationRequest(identifier: "claude.\(session.id).\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }

        if settings.soundEnabled {
            playCuteSound()
        }
    }

    private func playCuteSound() {
        // System "Glass" or "Tink" — light, friendly, non-startling.
        // Glass is the cutest of the built-ins.
        if let s = NSSound(named: NSSound.Name("Glass")) {
            s.volume = 0.5
            s.play()
        }
    }
}

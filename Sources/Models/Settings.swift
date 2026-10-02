import Foundation

// MARK: - Application Settings

struct AppSettings: Codable, Equatable, Sendable {
    var pollingInterval: TimeInterval  // >= 30 seconds
    var notificationsEnabled: Bool
    var badgeEnabled: Bool
    var debugMode: Bool
    var launchAtLogin: Bool

    static let `default` = AppSettings(
        pollingInterval: 60,
        notificationsEnabled: true,
        badgeEnabled: true,
        debugMode: false,
        launchAtLogin: false
    )
}

// MARK: - Notification Payload (ephemeral, not persisted)

struct NotificationPayload: Sendable {
    let title: String      // PR title
    let subtitle: String   // Repository name
    let body: String       // Event summary
    let debugAnnotation: String?  // Filter rule name in debug mode
    let prURL: URL
}

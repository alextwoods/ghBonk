import Foundation
@preconcurrency import UserNotifications
import OSLog

// MARK: - UNNotificationService

/// Concrete implementation of `SystemNotificationService` wrapping `UNUserNotificationCenter`.
///
/// Handles requesting notification permissions, delivering notifications, and managing
/// the application badge count on macOS 14+.
///
/// - Requirement 4.1: Delivers macOS notifications with PR title, repo name, and event summary.
/// - Requirement 4.4: Updates the Dock badge count for unread events.
struct UNNotificationService: SystemNotificationService {

    private let logger = Logger(subsystem: "dev.ghbonk", category: "notifications")

    /// Whether the notification center is available (requires a proper .app bundle).
    /// `UNUserNotificationCenter.current()` crashes with `NSInternalInconsistencyException`
    /// when run outside a .app bundle because `bundleProxyForCurrentProcess` is nil.
    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter {
        UNUserNotificationCenter.current()
    }

    // MARK: - Authorization

    /// Requests notification authorization for alerts, badges, and sounds.
    ///
    /// - Returns: `true` if authorization was granted, `false` otherwise.
    ///   Returns `false` when running outside a .app bundle.
    func requestAuthorization() async throws -> Bool {
        guard isAvailable else {
            logger.warning("Notifications unavailable: not running in a .app bundle")
            return false
        }
        return try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    // MARK: - Notification Delivery

    /// Delivers a macOS notification from the given payload.
    ///
    /// Creates a `UNMutableNotificationContent` with:
    /// - `title`: The PR title
    /// - `subtitle`: The repository name
    /// - `body`: The event summary, appended with the debug annotation if present
    /// - `sound`: Default notification sound
    /// - `userInfo`: Contains `prURL` so notification tap handlers can open the PR
    ///
    /// The notification is delivered immediately (nil trigger).
    /// No-ops when running outside a .app bundle.
    func deliver(notification: NotificationPayload) async throws {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle

        if let annotation = notification.debugAnnotation {
            content.body = "\(notification.body) [\(annotation)]"
        } else {
            content.body = notification.body
        }

        content.sound = .default
        content.userInfo = ["prURL": notification.prURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        try await center.add(request)
    }

    // MARK: - Badge Management

    /// Updates the application badge count.
    ///
    /// Uses `UNUserNotificationCenter.setBadgeCount(_:)` available on macOS 14+.
    /// No-ops when running outside a .app bundle.
    func setBadgeCount(_ count: Int) async throws {
        guard isAvailable else { return }
        try await center.setBadgeCount(count)
    }
}

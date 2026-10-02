import Foundation

// MARK: - System Notification Service Protocol

/// Abstraction over macOS UNUserNotificationCenter for testability.
/// Conforming types handle delivering notifications and managing badge count.
protocol SystemNotificationService: Sendable {
    func requestAuthorization() async throws -> Bool
    func deliver(notification: NotificationPayload) async throws
    func setBadgeCount(_ count: Int) async throws
}

// MARK: - Notification Engine

/// Bridges domain events to macOS desktop notifications.
///
/// Evaluates filtering rules via `FilterEngine`, delivers notifications when appropriate,
/// manages the dock badge count, and records notification history entries.
///
/// - Requirement 4.1: Delivers macOS notification with PR title, repo name, and event summary.
/// - Requirement 4.2: Respects global notification enable/disable toggle.
/// - Requirement 4.3: Manages badge count independently of notification delivery.
/// - Requirement 4.4: Increments badge count for delivered events when badge is enabled.
/// - Requirement 4.5: Decrements badge count when user views/dismisses notifications.
/// - Requirement 7.2: Annotates delivered notifications with rule name in debug mode.
/// - Requirement 7.3: Annotates suppressed history entries with rule name and reason in debug mode.
/// - Requirement 8.1: Maintains notification history log.
actor NotificationEngine {

    private let systemService: SystemNotificationService
    private var unreadCount: Int = 0
    private(set) var history: [NotificationHistoryEntry] = []

    init(systemService: SystemNotificationService) {
        self.systemService = systemService
    }

    // MARK: - Process Event

    /// Evaluates a PR event through the filter engine and handles notification delivery.
    ///
    /// - Parameters:
    ///   - event: The PR event to process.
    ///   - prRole: The user's role relative to the PR (authored/reviewing).
    ///   - rules: All filtering rules (enabled and disabled).
    ///   - settings: Current application settings.
    /// - Returns: The notification history entry created for this event.
    @discardableResult
    func process(
        event: PREvent,
        prRole: PRRole,
        rules: [FilteringRule],
        settings: AppSettings
    ) async -> NotificationHistoryEntry {
        let decision = FilterEngine.evaluate(
            event: event,
            prRole: prRole,
            rules: rules,
            debugMode: settings.debugMode
        )

        // Extract PR number from prIdentifier (format: "owner/repo#number")
        let prNumber = Int(event.prIdentifier.split(separator: "#").last ?? "") ?? 0

        let historyEntry = NotificationHistoryEntry(
            id: UUID(),
            timestamp: Date(),
            prTitle: event.prTitle,
            prIdentifier: event.prIdentifier,
            prNumber: prNumber,
            repository: event.repository,
            eventType: event.eventType,
            summary: event.summary,
            disposition: decision.disposition,
            matchedRuleName: decision.matchedRule?.name,
            reason: settings.debugMode ? decision.reason : nil,
            isRead: false
        )
        history.append(historyEntry)

        if decision.disposition == .delivered {
            if settings.notificationsEnabled {
                let payload = NotificationPayload(
                    title: event.prTitle,
                    subtitle: event.repository.fullName,
                    body: event.summary,
                    debugAnnotation: settings.debugMode ? decision.matchedRule?.name : nil,
                    prURL: URL(string: "https://github.com/\(event.repository.fullName)/pull/\(event.prIdentifier.split(separator: "#").last ?? "")")!
                )
                do {
                    try await systemService.deliver(notification: payload)
                } catch {
                    // Log delivery failure but don't throw — notification delivery
                    // is best-effort and shouldn't break the processing pipeline.
                }
            }

            if settings.badgeEnabled {
                unreadCount += 1
                do {
                    try await systemService.setBadgeCount(unreadCount)
                } catch {
                    // Badge update failure is non-fatal.
                }
            }
        }

        return historyEntry
    }

    // MARK: - Badge Management

    /// Decrements the unread count by the specified amount, clamping at zero.
    ///
    /// - Parameter count: The number of notifications the user has read/dismissed.
    func markRead(count: Int) async {
        unreadCount = max(0, unreadCount - count)
        do {
            try await systemService.setBadgeCount(unreadCount)
        } catch {
            // Badge update failure is non-fatal.
        }
    }

    // MARK: - Accessors

    /// Returns the current unread badge count.
    func getUnreadCount() -> Int {
        return unreadCount
    }

    /// Returns the current notification history.
    func getHistory() -> [NotificationHistoryEntry] {
        return history
    }

    /// Clears all notification history entries.
    func clearHistory() {
        history = []
    }
}

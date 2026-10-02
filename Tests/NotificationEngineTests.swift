import Foundation
import Testing
@testable import ghBonk

// MARK: - Mock System Notification Service

/// A mock implementation of `SystemNotificationService` for testing.
/// Records all calls so tests can assert on delivery behavior.
final class MockSystemNotificationService: SystemNotificationService, @unchecked Sendable {
    var deliveredNotifications: [NotificationPayload] = []
    var badgeCounts: [Int] = []
    var authorizationResult: Bool = true
    var shouldThrowOnDeliver: Bool = false
    var shouldThrowOnBadge: Bool = false

    func requestAuthorization() async throws -> Bool {
        return authorizationResult
    }

    func deliver(notification: NotificationPayload) async throws {
        if shouldThrowOnDeliver {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        deliveredNotifications.append(notification)
    }

    func setBadgeCount(_ count: Int) async throws {
        if shouldThrowOnBadge {
            throw NSError(domain: "test", code: 2, userInfo: nil)
        }
        badgeCounts.append(count)
    }
}

// MARK: - NotificationEngine Tests
// **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 7.2, 7.3, 8.1**

@Suite("NotificationEngine Tests")
struct NotificationEngineTests {

    // MARK: - Test Helpers

    private static let testRepo = Repository(
        id: UUID(),
        owner: "aws",
        name: "aws-sdk-java-v2",
        sortOrder: 0
    )

    private static func makeEvent(
        eventType: PREventType = .reviewRequested,
        summary: String = "Review requested from user"
    ) -> PREvent {
        PREvent(
            id: UUID(),
            prIdentifier: "aws/aws-sdk-java-v2#42",
            prTitle: "Fix serialization bug",
            repository: testRepo,
            eventType: eventType,
            timestamp: Date(),
            summary: summary
        )
    }

    private static func makeSettings(
        notificationsEnabled: Bool = true,
        badgeEnabled: Bool = true,
        debugMode: Bool = false
    ) -> AppSettings {
        AppSettings(
            pollingInterval: 60,
            notificationsEnabled: notificationsEnabled,
            badgeEnabled: badgeEnabled,
            debugMode: debugMode,
            launchAtLogin: false
        )
    }

    private static func makeRule(
        name: String = "Suppress Comments",
        description: String = "Suppress comment notifications",
        priority: Int = 1,
        isEnabled: Bool = true,
        predicate: FilterPredicate = .eventType(.commentAdded)
    ) -> FilteringRule {
        FilteringRule(
            id: UUID(),
            name: name,
            description: description,
            priority: priority,
            isEnabled: isEnabled,
            predicate: predicate
        )
    }

    /// A rule that matches any event — used in tests that focus on delivery/badge mechanics.
    private static let allowAllRule = FilteringRule(
        id: UUID(), name: "Allow All", description: "Allows everything",
        priority: 1, isEnabled: true, predicate: .compound([], mode: .allOf)  // Matches everything
    )

    // MARK: - Delivery Tests (Req 4.1, 4.2)

    @Test("Delivered event triggers system notification with correct payload")
    func deliveredEventTriggersNotification() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        await engine.process(
            event: event,
            prRole: .authored,
            rules: [Self.allowAllRule],  // No rules → default allow
            settings: settings
        )

        #expect(mockService.deliveredNotifications.count == 1)
        let payload = mockService.deliveredNotifications[0]
        #expect(payload.title == "Fix serialization bug")
        #expect(payload.subtitle == "aws/aws-sdk-java-v2")
        #expect(payload.body == "Review requested from user")
    }

    @Test("Notifications disabled prevents delivery but still records history")
    func notificationsDisabledNoDelivery() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(notificationsEnabled: false)

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [Self.allowAllRule],
            settings: settings
        )

        #expect(mockService.deliveredNotifications.isEmpty)
        #expect(entry.disposition == .delivered)
        let history = await engine.getHistory()
        #expect(history.count == 1)
    }

    @Test("Suppressed event does not trigger notification")
    func suppressedEventNoNotification() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(eventType: .commentAdded, summary: "Comment added")
        let settings = Self.makeSettings()

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [],  // Empty rules = no match = suppressed in allowlist model
            settings: settings
        )

        #expect(mockService.deliveredNotifications.isEmpty)
        #expect(entry.disposition == .suppressed)
    }

    // MARK: - Badge Tests (Req 4.3, 4.4, 4.5)

    @Test("Badge increments on delivered event when badge enabled")
    func badgeIncrementsOnDelivery() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(badgeEnabled: true)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        let count = await engine.getUnreadCount()
        #expect(count == 2)
        #expect(mockService.badgeCounts == [1, 2])
    }

    @Test("Badge does not increment when badge disabled")
    func badgeDisabledNoIncrement() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(badgeEnabled: false)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        let count = await engine.getUnreadCount()
        #expect(count == 0)
        #expect(mockService.badgeCounts.isEmpty)
    }

    @Test("Badge independent of notifications toggle")
    func badgeIndependentOfNotifications() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        // Notifications off, badge on
        let settings = Self.makeSettings(notificationsEnabled: false, badgeEnabled: true)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        #expect(mockService.deliveredNotifications.isEmpty)
        let count = await engine.getUnreadCount()
        #expect(count == 1)
        #expect(mockService.badgeCounts == [1])
    }

    @Test("Badge does not increment for suppressed events")
    func badgeNoIncrementForSuppressed() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(eventType: .commentAdded)
        let settings = Self.makeSettings(badgeEnabled: true)
        await engine.process(event: event, prRole: .authored, rules: [], settings: settings)

        let count = await engine.getUnreadCount()
        #expect(count == 0)
        #expect(mockService.badgeCounts.isEmpty)
    }

    @Test("markRead decrements badge count")
    func markReadDecrements() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        // Deliver 3 events
        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        await engine.markRead(count: 2)

        let count = await engine.getUnreadCount()
        #expect(count == 1)
    }

    @Test("markRead clamps at zero")
    func markReadClampsAtZero() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        await engine.markRead(count: 5)  // More than unread count

        let count = await engine.getUnreadCount()
        #expect(count == 0)
        // Last badge count set should be 0
        #expect(mockService.badgeCounts.last == 0)
    }

    // MARK: - History Tests (Req 8.1)

    @Test("Delivered events are recorded in history")
    func deliveredEventRecordedInHistory() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [Self.allowAllRule],
            settings: settings
        )

        #expect(entry.disposition == .delivered)
        #expect(entry.prTitle == "Fix serialization bug")
        #expect(entry.repository.fullName == "aws/aws-sdk-java-v2")
        #expect(entry.eventType == .reviewRequested)
        let history = await engine.getHistory()
        #expect(history.count == 1)
        #expect(history[0].id == entry.id)
    }

    @Test("Suppressed events are recorded in history")
    func suppressedEventRecordedInHistory() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(eventType: .commentAdded)
        let settings = Self.makeSettings()

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [],  // Empty rules = no match = suppressed in allowlist model
            settings: settings
        )

        #expect(entry.disposition == .suppressed)
        #expect(entry.matchedRuleName == nil)  // No rule matched = suppressed
        let history = await engine.getHistory()
        #expect(history.count == 1)
    }

    @Test("clearHistory empties history")
    func clearHistoryWorks() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        await engine.clearHistory()

        let history = await engine.getHistory()
        #expect(history.isEmpty)
    }

    // MARK: - Debug Mode Tests (Req 7.2, 7.3)

    @Test("Debug mode annotates delivered notification with rule info")
    func debugModeAnnotatesDelivered() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(debugMode: true)

        await engine.process(
            event: event,
            prRole: .authored,
            rules: [Self.allowAllRule],  // No matching rule → delivered
            settings: settings
        )

        let payload = mockService.deliveredNotifications[0]
        // In allowlist model, delivery is via matched rule, so annotation has the rule name
        #expect(payload.debugAnnotation == "Allow All")
    }

    @Test("Debug mode records reason for suppressed events")
    func debugModeRecordsSuppressionReason() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(eventType: .commentAdded)
        let settings = Self.makeSettings(debugMode: true)

        // In allowlist model, empty rules = suppressed with "no rule matches" reason
        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [],
            settings: settings
        )

        #expect(entry.disposition == .suppressed)
        #expect(entry.reason != nil)
        #expect(entry.reason!.contains("no rule matches"))
    }

    @Test("Non-debug mode does not record reason")
    func nonDebugModeNoReason() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(eventType: .commentAdded)
        let settings = Self.makeSettings(debugMode: false)

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [],  // No matching rule = suppressed
            settings: settings
        )

        #expect(entry.reason == nil)
    }

    // MARK: - Error Resilience Tests

    @Test("Delivery failure does not throw and still records history")
    func deliveryFailureResilient() async {
        let mockService = MockSystemNotificationService()
        mockService.shouldThrowOnDeliver = true
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [Self.allowAllRule],
            settings: settings
        )

        #expect(entry.disposition == .delivered)
        let history = await engine.getHistory()
        #expect(history.count == 1)
        // Badge should still increment since it's independent
        let count = await engine.getUnreadCount()
        #expect(count == 1)
    }

    @Test("Badge failure does not throw and still records history")
    func badgeFailureResilient() async {
        let mockService = MockSystemNotificationService()
        mockService.shouldThrowOnBadge = true
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings()

        let entry = await engine.process(
            event: event,
            prRole: .authored,
            rules: [Self.allowAllRule],
            settings: settings
        )

        #expect(entry.disposition == .delivered)
        let count = await engine.getUnreadCount()
        #expect(count == 1)
    }
}

import Foundation
import Testing
@testable import ghBonk

// MARK: - NotificationEngine Property Tests
// **Validates: Requirements 4.1, 4.4, 4.5**

@Suite("NotificationEngine Property Tests")
struct NotificationEnginePropertyTests {

    // MARK: - Test Helpers

    private static let testRepo = Repository(
        id: UUID(),
        owner: "aws",
        name: "aws-sdk-java-v2",
        sortOrder: 0
    )

    private static func makeEvent(
        eventType: PREventType = .reviewRequested,
        prTitle: String = "Fix serialization bug",
        summary: String = "Review requested from user"
    ) -> PREvent {
        PREvent(
            id: UUID(),
            prIdentifier: "aws/aws-sdk-java-v2#42",
            prTitle: prTitle,
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

    /// Allow-all rule for tests that focus on badge/delivery mechanics.
    private static let allowAllRule = FilteringRule(
        id: UUID(), name: "Allow", description: "Allow all",
        priority: 1, isEnabled: true, predicate: .compound([], mode: .allOf)  // Vacuous truth: matches everything
    )

    // MARK: - Property 12: Badge count invariant
    // After any sequence of deliveries and dismissals, badge = max(0, delivered - dismissed), never negative.
    // **Validates: Requirements 4.4, 4.5**

    @Test("Badge count invariant: badge equals max(0, delivered - read)",
          arguments: [
            (5, 2),   // 5 deliveries, 2 reads → badge = 3
            (3, 5),   // 3 deliveries, 5 reads → badge = 0 (clamped)
            (0, 3),   // 0 deliveries, 3 reads → badge = 0
            (10, 0),  // 10 deliveries, 0 reads → badge = 10
            (1, 1),   // 1 delivery, 1 read → badge = 0
            (7, 7),   // exact match → badge = 0
            (100, 50), // large counts → badge = 50
            (2, 10),  // much more reads than deliveries → badge = 0 (clamped)
          ])
    func badgeCountInvariant(scenario: (Int, Int)) async {
        let (deliveryCount, readCount) = scenario
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(badgeEnabled: true)

        // Deliver events
        for _ in 0..<deliveryCount {
            await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        }

        // Mark events as read
        await engine.markRead(count: readCount)

        let count = await engine.getUnreadCount()
        let expected = max(0, deliveryCount - readCount)
        #expect(count == expected,
                "After \(deliveryCount) deliveries and \(readCount) reads, badge should be \(expected) but was \(count)")
        #expect(count >= 0, "Badge count must never be negative")
    }

    @Test("Badge count invariant: alternating delivers and reads",
          arguments: [
            // Each tuple is (deliverBatch, readBatch) applied in sequence
            // deliver 1, read 1, deliver 2, read 1 → net delivered=3, read=2, badge=1
            ([(1, 1), (2, 1)], 1),
            // deliver 3, read 0, deliver 2, read 4 → net delivered=5, read=4, badge=1
            ([(3, 0), (2, 4)], 1),
            // deliver 1, read 5 (clamped), deliver 1, read 0 → badge=1
            ([(1, 5), (1, 0)], 1),
            // deliver 5, read 2, deliver 0, read 3 → badge=0
            ([(5, 2), (0, 3)], 0),
          ])
    func badgeCountInvariantAlternating(scenario: ([(Int, Int)], Int)) async {
        let (steps, expectedBadge) = scenario
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(badgeEnabled: true)

        for (deliveries, reads) in steps {
            for _ in 0..<deliveries {
                await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
            }
            await engine.markRead(count: reads)
        }

        let count = await engine.getUnreadCount()
        #expect(count == expectedBadge,
                "Badge count after alternating sequence should be \(expectedBadge) but was \(count)")
        #expect(count >= 0, "Badge count must never be negative")
    }

    @Test("Badge count invariant: suppressed events do not affect badge",
          arguments: [1, 3, 5, 10])
    func suppressedEventsDoNotAffectBadge(suppressedCount: Int) async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let settings = Self.makeSettings(badgeEnabled: true)

        // Send events with no matching rules = suppressed in allowlist model
        for _ in 0..<suppressedCount {
            let event = Self.makeEvent(eventType: .commentAdded, summary: "Comment added")
            await engine.process(event: event, prRole: .authored, rules: [], settings: settings)
        }

        let count = await engine.getUnreadCount()
        #expect(count == 0,
                "Badge should remain 0 after \(suppressedCount) suppressed events, got \(count)")
    }

    @Test("Badge count invariant: badge disabled means count stays at zero",
          arguments: [1, 3, 5, 10])
    func badgeDisabledCountStaysZero(deliveryCount: Int) async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(badgeEnabled: false)

        for _ in 0..<deliveryCount {
            await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        }

        let count = await engine.getUnreadCount()
        #expect(count == 0,
                "Badge should remain 0 when disabled, even after \(deliveryCount) deliveries, got \(count)")
        #expect(mockService.badgeCounts.isEmpty,
                "setBadgeCount should never be called when badge is disabled")
    }

    @Test("Badge count invariant: markRead never produces negative badge",
          arguments: [3, 5, 10, 100, 1000])
    func markReadNeverProducesNegativeBadge(excessiveReadCount: Int) async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent()
        let settings = Self.makeSettings(badgeEnabled: true)

        // Deliver exactly 2 events
        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)
        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        // Attempt to read more than delivered (all args > 2)
        await engine.markRead(count: excessiveReadCount)

        let count = await engine.getUnreadCount()
        #expect(count == 0, "Badge must clamp at 0, not go negative (got \(count))")
    }

    // MARK: - Property 13: Notification payload completeness
    // Delivered notifications have non-empty title, repo name, and summary.
    // **Validates: Requirements 4.1**

    @Test("Payload completeness: delivered notifications have non-empty title, subtitle, body",
          arguments: PREventType.allCases)
    func payloadCompletenessAllEventTypes(eventType: PREventType) async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(
            eventType: eventType,
            prTitle: "Add retry logic to HTTP client",
            summary: "Event: \(eventType.rawValue)"
        )
        let settings = Self.makeSettings(notificationsEnabled: true, badgeEnabled: true)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        #expect(mockService.deliveredNotifications.count == 1,
                "Should deliver exactly one notification for \(eventType.rawValue)")
        let payload = mockService.deliveredNotifications[0]
        #expect(!payload.title.isEmpty,
                "Payload title must be non-empty for event type \(eventType.rawValue)")
        #expect(!payload.subtitle.isEmpty,
                "Payload subtitle (repo name) must be non-empty for event type \(eventType.rawValue)")
        #expect(!payload.body.isEmpty,
                "Payload body (event summary) must be non-empty for event type \(eventType.rawValue)")
    }

    @Test("Payload completeness: title matches PR title",
          arguments: [
            "Fix serialization bug in DynamoDB mapper",
            "Add pagination support to list operations",
            "Upgrade Jackson to 2.15.x",
            "BREAKING: Remove deprecated waiters API",
            "chore: bump dependency versions",
          ])
    func payloadTitleMatchesPRTitle(prTitle: String) async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(prTitle: prTitle, summary: "Review requested")
        let settings = Self.makeSettings(notificationsEnabled: true)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        #expect(mockService.deliveredNotifications.count == 1)
        let payload = mockService.deliveredNotifications[0]
        #expect(payload.title == prTitle,
                "Payload title should match PR title '\(prTitle)', got '\(payload.title)'")
    }

    @Test("Payload completeness: subtitle matches repository full name",
          arguments: [
            ("aws", "aws-sdk-java-v2"),
            ("octocat", "hello-world"),
            ("my-org", "internal-service"),
          ])
    func payloadSubtitleMatchesRepoFullName(repoInfo: (String, String)) async {
        let (owner, name) = repoInfo
        let repo = Repository(id: UUID(), owner: owner, name: name, sortOrder: 0)
        let event = PREvent(
            id: UUID(),
            prIdentifier: "\(owner)/\(name)#1",
            prTitle: "Test PR",
            repository: repo,
            eventType: .reviewRequested,
            timestamp: Date(),
            summary: "Review requested"
        )
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let settings = Self.makeSettings(notificationsEnabled: true)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        #expect(mockService.deliveredNotifications.count == 1)
        let payload = mockService.deliveredNotifications[0]
        let expectedFullName = "\(owner)/\(name)"
        #expect(payload.subtitle == expectedFullName,
                "Payload subtitle should be '\(expectedFullName)', got '\(payload.subtitle)'")
    }

    @Test("Payload completeness: body matches event summary",
          arguments: [
            "Review requested from @octocat",
            "CI check 'Build SDK' completed with failure",
            "Pull request was merged",
            "New comment: 'LGTM, ship it!'",
            "Changes requested by @reviewer",
          ])
    func payloadBodyMatchesEventSummary(summary: String) async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(summary: summary)
        let settings = Self.makeSettings(notificationsEnabled: true)

        await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        #expect(mockService.deliveredNotifications.count == 1)
        let payload = mockService.deliveredNotifications[0]
        #expect(payload.body == summary,
                "Payload body should be '\(summary)', got '\(payload.body)'")
    }

    @Test("Payload completeness: notifications disabled prevents delivery but payload would be valid")
    func notificationsDisabledNoPayloadDelivered() async {
        let mockService = MockSystemNotificationService()
        let engine = NotificationEngine(systemService: mockService)
        let event = Self.makeEvent(
            prTitle: "Important PR",
            summary: "Critical review needed"
        )
        let settings = Self.makeSettings(notificationsEnabled: false)

        let entry = await engine.process(event: event, prRole: .authored, rules: [Self.allowAllRule], settings: settings)

        // Notification is not delivered when disabled, but disposition is still "delivered"
        #expect(mockService.deliveredNotifications.isEmpty,
                "System notification should not be sent when notifications are disabled")
        #expect(entry.disposition == .delivered,
                "Disposition should still be 'delivered' even when notifications are off")
    }
}

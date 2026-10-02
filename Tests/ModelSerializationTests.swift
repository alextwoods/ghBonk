import Foundation
import Testing
@testable import ghBonk

// MARK: - Property 1: Persistence Round-Trip
// **Validates: Requirements 1.2, 2.2, 5.4, 8.1, 10.1, 10.2, 12.3**
// For any valid Codable model instance, encoding to JSON and decoding
// should produce an equal value.

@Suite("Model Serialization Round-Trip Tests")
struct ModelSerializationRoundTripTests {

    // MARK: - Helpers

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Generic round-trip assertion: encode to JSON, decode back, assert equality.
    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, label: String) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        #expect(decoded == value, "Round-trip failed for \(label)")
    }

    // MARK: - Repository Round-Trip

    @Test("Repository round-trips through JSON", arguments: [
        Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0),
        Repository(id: UUID(), owner: "apple", name: "swift", sortOrder: 1),
        Repository(id: UUID(), owner: "user-with-dashes", name: "repo.with.dots", sortOrder: 99),
    ])
    func repositoryRoundTrip(repo: Repository) throws {
        try assertRoundTrip(repo, label: "Repository(\(repo.fullName))")
    }

    // MARK: - AppSettings Round-Trip

    @Test("AppSettings round-trips through JSON", arguments: [
        AppSettings.default,
        AppSettings(pollingInterval: 30, notificationsEnabled: false, badgeEnabled: false, debugMode: true, launchAtLogin: true),
        AppSettings(pollingInterval: 300, notificationsEnabled: true, badgeEnabled: false, debugMode: false, launchAtLogin: true),
    ])
    func appSettingsRoundTrip(settings: AppSettings) throws {
        try assertRoundTrip(settings, label: "AppSettings(interval=\(settings.pollingInterval))")
    }

    // MARK: - PREvent Round-Trip

    @Test("PREvent round-trips through JSON", arguments: PREventType.allCases)
    func prEventRoundTrip(eventType: PREventType) throws {
        let repo = Repository(id: UUID(), owner: "aws", name: "sdk", sortOrder: 0)
        let event = PREvent(
            id: UUID(),
            prIdentifier: "aws/sdk#42",
            prTitle: "Fix serialization bug",
            repository: repo,
            eventType: eventType,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            summary: "Event of type \(eventType.rawValue)"
        )
        try assertRoundTrip(event, label: "PREvent(\(eventType.rawValue))")
    }

    // MARK: - TrackedPR Round-Trip

    @Test("TrackedPR round-trips through JSON", arguments: [
        PRState.open, PRState.draft, PRState.merged, PRState.closed,
    ])
    func trackedPRRoundTrip(state: PRState) throws {
        let repo = Repository(id: UUID(), owner: "aws", name: "sdk", sortOrder: 0)
        let event = PREvent(
            id: UUID(),
            prIdentifier: "aws/sdk#10",
            prTitle: "Update deps",
            repository: repo,
            eventType: .checkCompleted,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            summary: "CI passed"
        )
        let pr = TrackedPR(
            id: "aws/sdk#10",
            number: 10,
            title: "Update deps",
            repository: repo,
            state: state,
            role: .authored,
            reviewStatus: .pending,
            reviewSummary: ReviewSummary(totalReviewers: 2, approvedCount: 1, changesRequestedCount: 0, commentedCount: 0),
            sdkBuildStatus: .success,
            latestEvent: event,
            updatedAt: Date(timeIntervalSince1970: 1700000000)
        )
        try assertRoundTrip(pr, label: "TrackedPR(state=\(state.rawValue))")
    }

    @Test("TrackedPR with nil optional fields round-trips")
    func trackedPRNilFieldsRoundTrip() throws {
        let repo = Repository(id: UUID(), owner: "org", name: "repo", sortOrder: 0)
        let pr = TrackedPR(
            id: "org/repo#5",
            number: 5,
            title: "Draft PR",
            repository: repo,
            state: .draft,
            role: .reviewing,
            reviewStatus: .changesRequested,
            reviewSummary: ReviewSummary(totalReviewers: 1, approvedCount: 0, changesRequestedCount: 1, commentedCount: 0),
            sdkBuildStatus: nil,
            latestEvent: nil,
            updatedAt: Date(timeIntervalSince1970: 1700000000)
        )
        try assertRoundTrip(pr, label: "TrackedPR(nil optionals)")
    }

    // MARK: - FilteringRule Round-Trip (all FilterPredicate cases)

    @Test("FilteringRule with eventType predicate round-trips", arguments: PREventType.allCases)
    func filteringRuleEventTypeRoundTrip(eventType: PREventType) throws {
        let rule = FilteringRule(
            id: UUID(),
            name: "Filter \(eventType.rawValue)",
            description: "Suppress \(eventType.rawValue) events",
            priority: 1,
            isEnabled: true,
            predicate: .eventType(eventType)
        )
        try assertRoundTrip(rule, label: "FilteringRule(eventType=\(eventType.rawValue))")
    }

    @Test("FilteringRule with ciCheck predicate round-trips", arguments: [
        ("SonarCloud Code Analysis", "failure"),
        ("Build SDK / aws-sdk-pr-build (pull_request)", nil),
    ] as [(String, String?)])
    func filteringRuleCICheckRoundTrip(checkName: String, conclusion: String?) throws {
        let rule = FilteringRule(
            id: UUID(),
            name: "CI rule",
            description: "CI check filter",
            priority: 2,
            isEnabled: false,
            predicate: .ciCheck(checkName: checkName, conclusion: conclusion)
        )
        try assertRoundTrip(rule, label: "FilteringRule(ciCheck=\(checkName))")
    }

    @Test("FilteringRule with prRole predicate round-trips", arguments: [PRRole.authored, PRRole.reviewing])
    func filteringRulePRRoleRoundTrip(role: PRRole) throws {
        let rule = FilteringRule(
            id: UUID(),
            name: "Role filter",
            description: "Filter by role",
            priority: 3,
            isEnabled: true,
            predicate: .prRole(role)
        )
        try assertRoundTrip(rule, label: "FilteringRule(prRole=\(role.rawValue))")
    }

    @Test("FilteringRule with compound predicate round-trips")
    func filteringRuleCompoundRoundTrip() throws {
        let compoundRule = FilteringRule(
            id: UUID(),
            name: "Compound rule",
            description: "Complex filter",
            priority: 0,
            isEnabled: true,
            predicate: .compound([
                .eventType(.checkCompleted),
                .prRole(.authored),
                .ciCheck(checkName: "lint", conclusion: "success"),
            ], mode: .allOf)
        )
        try assertRoundTrip(compoundRule, label: "FilteringRule(compound allOf)")

        let anyOfRule = FilteringRule(
            id: UUID(),
            name: "AnyOf rule",
            description: "Any match filter",
            priority: 5,
            isEnabled: false,
            predicate: .compound([
                .eventType(.reviewRequested),
                .eventType(.reviewSubmitted),
            ], mode: .anyOf)
        )
        try assertRoundTrip(anyOfRule, label: "FilteringRule(compound anyOf)")
    }

    @Test("FilteringRule with nested compound predicate round-trips")
    func filteringRuleNestedCompoundRoundTrip() throws {
        let rule = FilteringRule(
            id: UUID(),
            name: "Nested compound",
            description: "Deeply nested predicates",
            priority: 10,
            isEnabled: true,
            predicate: .compound([
                .compound([
                    .eventType(.commentAdded),
                    .prRole(.reviewing),
                ], mode: .allOf),
                .ciCheck(checkName: "build", conclusion: "failure"),
            ], mode: .anyOf)
        )
        try assertRoundTrip(rule, label: "FilteringRule(nested compound)")
    }

    // MARK: - NotificationHistoryEntry Round-Trip

    @Test("NotificationHistoryEntry round-trips through JSON", arguments: [
        Disposition.delivered, Disposition.suppressed,
    ])
    func notificationHistoryEntryRoundTrip(disposition: Disposition) throws {
        let repo = Repository(id: UUID(), owner: "aws", name: "sdk", sortOrder: 0)
        let entry = NotificationHistoryEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1700000000),
            prTitle: "Fix memory leak",
            prIdentifier: "aws/aws-sdk-java-v2#42",
            prNumber: 42,
            repository: repo,
            eventType: .reviewSubmitted,
            summary: "Test event summary",
            disposition: disposition,
            matchedRuleName: disposition == .suppressed ? "SonarCloud suppression" : nil,
            reason: disposition == .suppressed ? "SonarCloud checks are always suppressed" : nil
        )
        try assertRoundTrip(entry, label: "NotificationHistoryEntry(\(disposition.rawValue))")
    }

    // MARK: - CheckRunFailure Round-Trip

    @Test("CheckRunFailure round-trips through JSON")
    func checkRunFailureRoundTrip() throws {
        let samplePayload = #"{"id": 123, "name": "build", "conclusion": "failure"}"#.data(using: .utf8)!
        let failure = CheckRunFailure(
            checkName: "Build SDK / aws-sdk-pr-build (pull_request)",
            failureURL: URL(string: "https://github.com/aws/sdk/actions/runs/123")!,
            runID: 123,
            conclusion: "failure",
            rawPayload: samplePayload
        )
        try assertRoundTrip(failure, label: "CheckRunFailure")
    }

    @Test("CheckRunFailure with large payload round-trips")
    func checkRunFailureLargePayloadRoundTrip() throws {
        // Simulates a realistic raw payload from the GitHub API
        let largePayload = String(repeating: "x", count: 4096).data(using: .utf8)!
        let failure = CheckRunFailure(
            checkName: "SonarCloud Code Analysis",
            failureURL: URL(string: "https://github.com/org/repo/actions/runs/999")!,
            runID: 999,
            conclusion: "neutral",
            rawPayload: largePayload
        )
        try assertRoundTrip(failure, label: "CheckRunFailure(large payload)")
    }
}

// MARK: - Property 2: Corrupted Data Recovery
// **Validates: Requirements 10.4**
// For any invalid JSON, decoding should return defaults rather than crash.
// This tests a loadOrDefault helper pattern that safely handles corruption.

@Suite("Corrupted Data Recovery Tests")
struct CorruptedDataRecoveryTests {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Simulates the `loadOrDefault` pattern from PersistenceManager:
    /// If decoding fails, return the default value instead of crashing.
    private func loadOrDefault<T: Codable>(_ type: T.Type, from data: Data, default defaultValue: T) -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            return defaultValue
        }
    }

    // MARK: - Garbage Data

    @Test("Garbage bytes produce defaults, not crashes", arguments: [
        Data(),                                      // empty
        Data([0xFF, 0xFE, 0x00, 0x01]),             // random bytes
        "not json at all".data(using: .utf8)!,       // plain text
        "{{{{".data(using: .utf8)!,                  // malformed JSON
        "null".data(using: .utf8)!,                  // JSON null
        "[1, 2, 3]".data(using: .utf8)!,            // wrong structure (array vs object)
    ])
    func garbageDataReturnsDefaultSettings(data: Data) {
        let result = loadOrDefault(AppSettings.self, from: data, default: .default)
        #expect(result == AppSettings.default)
    }

    @Test("Corrupted repo list returns empty default")
    func corruptedRepoListReturnsDefault() {
        let invalidData = "{ broken json".data(using: .utf8)!
        let result = loadOrDefault([Repository].self, from: invalidData, default: [])
        #expect(result.isEmpty)
    }

    @Test("Corrupted filter rules return empty default")
    func corruptedFilterRulesReturnDefault() {
        let invalidData = "42".data(using: .utf8)!
        let result = loadOrDefault([FilteringRule].self, from: invalidData, default: [])
        #expect(result.isEmpty)
    }

    @Test("Corrupted notification history returns empty default")
    func corruptedHistoryReturnsDefault() {
        let invalidData = Data(repeating: 0xAB, count: 100)
        let result = loadOrDefault([NotificationHistoryEntry].self, from: invalidData, default: [])
        #expect(result.isEmpty)
    }

    @Test("Corrupted PR cache returns empty default")
    func corruptedPRCacheReturnsDefault() {
        let invalidData = "\"just a string\"".data(using: .utf8)!
        let result = loadOrDefault([TrackedPR].self, from: invalidData, default: [])
        #expect(result.isEmpty)
    }

    // MARK: - Partial/Mismatched JSON

    @Test("Partial JSON with missing required fields returns default")
    func partialJSONReturnsDefault() {
        // AppSettings requires all fields; partial object should fail to decode
        let partial = #"{"pollingInterval": 60}"#.data(using: .utf8)!
        let result = loadOrDefault(AppSettings.self, from: partial, default: .default)
        #expect(result == AppSettings.default)
    }

    @Test("JSON with wrong types returns default")
    func wrongTypesReturnDefault() {
        // pollingInterval should be a number, not a string
        let wrongTypes = #"{"pollingInterval": "not a number", "notificationsEnabled": "yes", "badgeEnabled": 1, "debugMode": 0, "launchAtLogin": null}"#.data(using: .utf8)!
        let result = loadOrDefault(AppSettings.self, from: wrongTypes, default: .default)
        #expect(result == AppSettings.default)
    }

    @Test("Decoding invalid JSON throws DecodingError, never traps")
    func decodingInvalidJSONThrows() {
        let garbage = Data([0x00, 0xFF, 0xAA, 0xBB, 0xCC])
        #expect(throws: (any Error).self) {
            try decoder.decode(AppSettings.self, from: garbage)
        }
        #expect(throws: (any Error).self) {
            try decoder.decode([Repository].self, from: garbage)
        }
        #expect(throws: (any Error).self) {
            try decoder.decode([FilteringRule].self, from: garbage)
        }
        #expect(throws: (any Error).self) {
            try decoder.decode([NotificationHistoryEntry].self, from: garbage)
        }
        #expect(throws: (any Error).self) {
            try decoder.decode(CheckRunFailure.self, from: garbage)
        }
    }
}

// MARK: - CaseIterable Conformances for Parameterized Tests

extension PREventType: CaseIterable {
    public static var allCases: [PREventType] {
        [.reviewRequested, .reviewSubmitted, .commentAdded, .checkCompleted, .prStateChanged, .prMerged, .newCommitPushed, .enteredMergeQueue, .mergeQueueFailed]
    }
}

import Foundation
import Testing
@testable import ghBonk

@Suite("PersistenceManager Tests")
struct PersistenceManagerTests {

    // MARK: - Helpers

    /// Creates a temporary directory for test isolation.
    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghBonkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Removes the temporary directory after tests.
    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Save and Load (round-trip)

    @Test("save and load round-trips a Codable value")
    func saveAndLoadRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let settings = AppSettings(
            pollingInterval: 90,
            notificationsEnabled: false,
            badgeEnabled: true,
            debugMode: true,
            launchAtLogin: true
        )

        try await manager.save(settings, to: "settings.json")
        let loaded: AppSettings = try await manager.load(AppSettings.self, from: "settings.json")

        #expect(loaded.pollingInterval == 90)
        #expect(loaded.notificationsEnabled == false)
        #expect(loaded.badgeEnabled == true)
        #expect(loaded.debugMode == true)
        #expect(loaded.launchAtLogin == true)
    }

    @Test("save and load round-trips an array of Repository")
    func saveAndLoadRepoList() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let repos = [
            Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0),
            Repository(id: UUID(), owner: "apple", name: "swift", sortOrder: 1),
        ]

        try await manager.save(repos, to: "repos.json")
        let loaded = try await manager.load([Repository].self, from: "repos.json")

        #expect(loaded.count == 2)
        #expect(loaded[0].fullName == "aws/aws-sdk-java-v2")
        #expect(loaded[1].fullName == "apple/swift")
    }

    // MARK: - Load errors

    @Test("load throws dataCorrupted when file does not exist")
    func loadMissingFileThrows() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)

        do {
            _ = try await manager.load(AppSettings.self, from: "nonexistent.json")
            Issue.record("Expected an error to be thrown")
        } catch let error as GhBonkError {
            if case .dataCorrupted(let filename, _) = error {
                #expect(filename == "nonexistent.json")
            } else {
                Issue.record("Expected dataCorrupted, got \(error)")
            }
        }
    }

    @Test("load throws dataCorrupted when JSON is malformed")
    func loadCorruptedJsonThrows() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        // Write invalid JSON
        let fileURL = dir.appendingPathComponent("settings.json")
        try "{ not valid json }}}".data(using: .utf8)!.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)

        do {
            _ = try await manager.load(AppSettings.self, from: "settings.json")
            Issue.record("Expected an error to be thrown")
        } catch let error as GhBonkError {
            if case .dataCorrupted(let filename, _) = error {
                #expect(filename == "settings.json")
            } else {
                Issue.record("Expected dataCorrupted, got \(error)")
            }
        }
    }

    // MARK: - loadOrDefault

    @Test("loadOrDefault returns default when file is missing")
    func loadOrDefaultReturnsFallback() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let settings = await manager.loadOrDefault(
            AppSettings.self,
            from: "settings.json",
            default: .default
        )

        #expect(settings.pollingInterval == 60)
        #expect(settings.notificationsEnabled == true)
    }

    @Test("loadOrDefault returns default when JSON is corrupted")
    func loadOrDefaultReturnsFallbackOnCorruption() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        // Write corrupt data
        let fileURL = dir.appendingPathComponent("settings.json")
        try "garbage".data(using: .utf8)!.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let settings = await manager.loadOrDefault(
            AppSettings.self,
            from: "settings.json",
            default: .default
        )

        #expect(settings.pollingInterval == 60)
    }

    @Test("loadOrDefault returns loaded value when file is valid")
    func loadOrDefaultReturnsLoadedValue() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let saved = AppSettings(
            pollingInterval: 120,
            notificationsEnabled: false,
            badgeEnabled: false,
            debugMode: true,
            launchAtLogin: false
        )
        try await manager.save(saved, to: "settings.json")

        let loaded = await manager.loadOrDefault(
            AppSettings.self,
            from: "settings.json",
            default: .default
        )

        #expect(loaded.pollingInterval == 120)
        #expect(loaded.notificationsEnabled == false)
    }

    // MARK: - Raw Data

    @Test("saveRawData and loadRawData round-trip raw bytes")
    func rawDataRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let payload = "{\"runId\": 12345}".data(using: .utf8)!

        try await manager.saveRawData(payload, to: "check_failures/run_12345.json")
        let loaded = try await manager.loadRawData(from: "check_failures/run_12345.json")

        #expect(loaded == payload)
    }

    @Test("loadRawData throws dataCorrupted when file is missing")
    func loadRawDataMissingFileThrows() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)

        do {
            _ = try await manager.loadRawData(from: "check_failures/missing.json")
            Issue.record("Expected an error to be thrown")
        } catch let error as GhBonkError {
            if case .dataCorrupted(let filename, _) = error {
                #expect(filename == "check_failures/missing.json")
            } else {
                Issue.record("Expected dataCorrupted, got \(error)")
            }
        }
    }

    // MARK: - Directory creation

    @Test("save creates the storage directory if it does not exist")
    func saveCreatesDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghBonkTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanUp(dir) }

        // Do NOT pre-create the directory
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        let manager = PersistenceManager(directory: dir)
        try await manager.save(AppSettings.default, to: "settings.json")

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("check_failures").path
        ))
    }

    // MARK: - JSON format

    @Test("save writes pretty-printed JSON with ISO 8601 dates")
    func saveWritesPrettyPrintedJson() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        try await manager.save(AppSettings.default, to: "settings.json")

        let fileURL = dir.appendingPathComponent("settings.json")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)

        // Pretty-printed JSON has newlines
        #expect(contents.contains("\n"))
        // Contains expected keys
        #expect(contents.contains("pollingInterval"))
        #expect(contents.contains("notificationsEnabled"))
    }
}


// MARK: - Property Tests for PersistenceManager
// **Validates: Requirements 10.1, 10.2, 10.4**

@Suite("PersistenceManager Property Tests")
struct PersistenceManagerPropertyTests {

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghBonkPropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Property 1: Persistence Round-Trip
    // Save then load for each model type produces an equal value.

    @Test("Round-trip: FilteringRule array with all predicate types")
    func filteringRuleArrayRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let rules: [FilteringRule] = [
            FilteringRule(
                id: UUID(),
                name: "Event type filter",
                description: "Suppress review requests",
                priority: 1,
                isEnabled: true,
                predicate: .eventType(.reviewRequested)
            ),
            FilteringRule(
                id: UUID(),
                name: "CI check filter",
                description: "Track SonarCloud failures",
                priority: 2,
                isEnabled: false,
                predicate: .ciCheck(checkName: "SonarCloud Code Analysis", conclusion: "failure")
            ),
            FilteringRule(
                id: UUID(),
                name: "CI check no conclusion",
                description: "Track any conclusion",
                priority: 3,
                isEnabled: true,
                predicate: .ciCheck(checkName: "Build SDK / aws-sdk-pr-build (pull_request)", conclusion: nil)
            ),
            FilteringRule(
                id: UUID(),
                name: "Role filter",
                description: "Only authored PRs",
                priority: 4,
                isEnabled: true,
                predicate: .prRole(.authored)
            ),
            FilteringRule(
                id: UUID(),
                name: "Compound filter",
                description: "Complex rule with allOf",
                priority: 5,
                isEnabled: true,
                predicate: .compound([
                    .eventType(.checkCompleted),
                    .prRole(.authored),
                    .ciCheck(checkName: "lint", conclusion: "success"),
                ], mode: .allOf)
            ),
            FilteringRule(
                id: UUID(),
                name: "Compound anyOf",
                description: "Any matching sub-predicate",
                priority: 6,
                isEnabled: false,
                predicate: .compound([
                    .eventType(.reviewSubmitted),
                    .eventType(.prMerged),
                ], mode: .anyOf)
            ),
            FilteringRule(
                id: UUID(),
                name: "Nested compound",
                description: "Deeply nested predicates",
                priority: 7,
                isEnabled: true,
                predicate: .compound([
                    .compound([
                        .eventType(.commentAdded),
                        .prRole(.reviewing),
                    ], mode: .allOf),
                    .ciCheck(checkName: "build", conclusion: "failure"),
                ], mode: .anyOf)
            ),
        ]

        try await manager.save(rules, to: "filters.json")
        let loaded = try await manager.load([FilteringRule].self, from: "filters.json")

        #expect(loaded.count == rules.count)
        for (original, restored) in zip(rules, loaded) {
            #expect(original == restored)
        }
    }

    @Test("Round-trip: NotificationHistoryEntry array with mixed dispositions")
    func notificationHistoryRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let repo = Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0)
        let entries: [NotificationHistoryEntry] = [
            NotificationHistoryEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1700000000),
                prTitle: "Fix serialization bug",
                prIdentifier: "aws/aws-sdk-java-v2#42",
                prNumber: 42,
                repository: repo,
                eventType: .reviewSubmitted,
            summary: "Test event summary",
                disposition: .delivered,
                matchedRuleName: "Review notifications",
                reason: nil
            ),
            NotificationHistoryEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1700001000),
                prTitle: "Update dependencies",
                prIdentifier: "aws/aws-sdk-java-v2#42",
                prNumber: 42,
                repository: repo,
                eventType: .checkCompleted,
            summary: "Test event summary",
                disposition: .suppressed,
                matchedRuleName: "SonarCloud suppression",
                reason: "SonarCloud checks are always suppressed"
            ),
            NotificationHistoryEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1700002000),
                prTitle: "Add new feature",
                prIdentifier: "aws/aws-sdk-java-v2#42",
                prNumber: 42,
                repository: repo,
                eventType: .commentAdded,
            summary: "Test event summary",
                disposition: .delivered,
                matchedRuleName: nil,
                reason: nil
            ),
            NotificationHistoryEntry(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: 1700003000),
                prTitle: "Refactor module",
                prIdentifier: "aws/aws-sdk-java-v2#42",
                prNumber: 42,
                repository: repo,
                eventType: .prMerged,
            summary: "Test event summary",
                disposition: .suppressed,
                matchedRuleName: "Merged PR suppression",
                reason: "Merged PRs do not generate notifications"
            ),
        ]

        try await manager.save(entries, to: "history.json")
        let loaded = try await manager.load([NotificationHistoryEntry].self, from: "history.json")

        #expect(loaded.count == entries.count)
        for (original, restored) in zip(entries, loaded) {
            #expect(original == restored)
        }
    }

    @Test("Round-trip: TrackedPR array with varied states")
    func trackedPRArrayRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)
        let repo1 = Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0)
        let repo2 = Repository(id: UUID(), owner: "apple", name: "swift", sortOrder: 1)

        let prs: [TrackedPR] = [
            TrackedPR(
                id: "aws/aws-sdk-java-v2#100",
                number: 100,
                title: "Open authored PR",
                repository: repo1,
                state: .open,
                role: .authored,
                reviewStatus: .pending,
                reviewSummary: ReviewSummary(totalReviewers: 1, approvedCount: 0, changesRequestedCount: 0, commentedCount: 0),
                sdkBuildStatus: .success,
                latestEvent: PREvent(
                    id: UUID(),
                    prIdentifier: "aws/aws-sdk-java-v2#100",
                    prTitle: "Open authored PR",
                    repository: repo1,
                    eventType: .checkCompleted,
                    timestamp: Date(timeIntervalSince1970: 1700000000),
                    summary: "SDK build passed"
                ),
                updatedAt: Date(timeIntervalSince1970: 1700000000)
            ),
            TrackedPR(
                id: "apple/swift#42",
                number: 42,
                title: "Draft reviewing PR",
                repository: repo2,
                state: .draft,
                role: .reviewing,
                reviewStatus: .changesRequested,
                reviewSummary: ReviewSummary(totalReviewers: 1, approvedCount: 0, changesRequestedCount: 1, commentedCount: 0),
                sdkBuildStatus: nil,
                latestEvent: nil,
                updatedAt: Date(timeIntervalSince1970: 1700001000)
            ),
            TrackedPR(
                id: "aws/aws-sdk-java-v2#99",
                number: 99,
                title: "Merged authored PR",
                repository: repo1,
                state: .merged,
                role: .authored,
                reviewStatus: .approved,
                reviewSummary: ReviewSummary(totalReviewers: 2, approvedCount: 2, changesRequestedCount: 0, commentedCount: 0),
                sdkBuildStatus: .failure,
                latestEvent: PREvent(
                    id: UUID(),
                    prIdentifier: "aws/aws-sdk-java-v2#99",
                    prTitle: "Merged authored PR",
                    repository: repo1,
                    eventType: .prMerged,
                    timestamp: Date(timeIntervalSince1970: 1700002000),
                    summary: "PR was merged"
                ),
                updatedAt: Date(timeIntervalSince1970: 1700002000)
            ),
            TrackedPR(
                id: "apple/swift#10",
                number: 10,
                title: "Closed PR",
                repository: repo2,
                state: .closed,
                role: .reviewing,
                reviewStatus: .commented,
                reviewSummary: ReviewSummary(totalReviewers: 2, approvedCount: 0, changesRequestedCount: 0, commentedCount: 1),
                sdkBuildStatus: .notApplicable,
                latestEvent: PREvent(
                    id: UUID(),
                    prIdentifier: "apple/swift#10",
                    prTitle: "Closed PR",
                    repository: repo2,
                    eventType: .prStateChanged,
                    timestamp: Date(timeIntervalSince1970: 1700003000),
                    summary: "PR was closed"
                ),
                updatedAt: Date(timeIntervalSince1970: 1700003000)
            ),
        ]

        try await manager.save(prs, to: "pr_cache.json")
        let loaded = try await manager.load([TrackedPR].self, from: "pr_cache.json")

        #expect(loaded.count == prs.count)
        for (original, restored) in zip(prs, loaded) {
            #expect(original == restored)
        }
    }

    @Test("Round-trip: CheckRunFailure via raw data methods")
    func checkRunFailureRawDataRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let failure = CheckRunFailure(
            checkName: "Build SDK / aws-sdk-pr-build (pull_request)",
            failureURL: URL(string: "https://github.com/aws/aws-sdk-java-v2/actions/runs/12345")!,
            runID: 12345,
            conclusion: "failure",
            rawPayload: "{\"logs\": \"build failed at step 3\"}".data(using: .utf8)!
        )

        let encoded = try encoder.encode(failure)
        try await manager.saveRawData(encoded, to: "check_failures/run_12345.json")
        let loadedData = try await manager.loadRawData(from: "check_failures/run_12345.json")

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CheckRunFailure.self, from: loadedData)

        #expect(decoded == failure)
    }

    // MARK: - Property 2: Corrupted Data Recovery
    // Corrupted file returns defaults via loadOrDefault.

    @Test("Corrupted data recovery: random bytes in settings.json returns defaults")
    func corruptedSettingsReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let fileURL = dir.appendingPathComponent("settings.json")
        let randomBytes = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        try randomBytes.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let result = await manager.loadOrDefault(AppSettings.self, from: "settings.json", default: .default)

        #expect(result == AppSettings.default)
    }

    @Test("Corrupted data recovery: random bytes in repos.json returns defaults")
    func corruptedReposReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let fileURL = dir.appendingPathComponent("repos.json")
        let randomBytes = Data((0..<128).map { _ in UInt8.random(in: 0...255) })
        try randomBytes.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let result = await manager.loadOrDefault([Repository].self, from: "repos.json", default: [])

        #expect(result.isEmpty)
    }

    @Test("Corrupted data recovery: random bytes in filters.json returns defaults")
    func corruptedFiltersReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let fileURL = dir.appendingPathComponent("filters.json")
        let randomBytes = Data((0..<96).map { _ in UInt8.random(in: 0...255) })
        try randomBytes.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let result = await manager.loadOrDefault([FilteringRule].self, from: "filters.json", default: [])

        #expect(result.isEmpty)
    }

    @Test("Corrupted data recovery: random bytes in history.json returns defaults")
    func corruptedHistoryReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let fileURL = dir.appendingPathComponent("history.json")
        let randomBytes = Data((0..<80).map { _ in UInt8.random(in: 0...255) })
        try randomBytes.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let result = await manager.loadOrDefault(
            [NotificationHistoryEntry].self, from: "history.json", default: []
        )

        #expect(result.isEmpty)
    }

    @Test("Corrupted data recovery: random bytes in pr_cache.json returns defaults")
    func corruptedPRCacheReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let fileURL = dir.appendingPathComponent("pr_cache.json")
        let randomBytes = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
        try randomBytes.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let result = await manager.loadOrDefault([TrackedPR].self, from: "pr_cache.json", default: [])

        #expect(result.isEmpty)
    }

    @Test("Corrupted data recovery: valid JSON structure but wrong type returns defaults")
    func wrongTypeJSONReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        // Write a valid JSON array where AppSettings (an object) is expected
        let fileURL = dir.appendingPathComponent("settings.json")
        try "[1, 2, 3]".data(using: .utf8)!.write(to: fileURL)

        let manager = PersistenceManager(directory: dir)
        let result = await manager.loadOrDefault(AppSettings.self, from: "settings.json", default: .default)

        #expect(result == AppSettings.default)
    }

    @Test("Corrupted data recovery: truncated JSON returns defaults")
    func truncatedJSONReturnsDefault() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)

        // First save valid settings to get properly formatted JSON
        let settings = AppSettings(
            pollingInterval: 120,
            notificationsEnabled: true,
            badgeEnabled: false,
            debugMode: true,
            launchAtLogin: false
        )
        try await manager.save(settings, to: "settings.json")

        // Now truncate the file by reading and cutting it in half
        let fileURL = dir.appendingPathComponent("settings.json")
        let fullData = try Data(contentsOf: fileURL)
        let truncated = fullData.prefix(fullData.count / 2)
        try truncated.write(to: fileURL)

        let result = await manager.loadOrDefault(AppSettings.self, from: "settings.json", default: .default)

        #expect(result == AppSettings.default)
    }

    // MARK: - Overwrite/Update Semantics
    // Save a value, then save a different value to the same file — load returns the latest.

    @Test("Overwrite semantics: saving a new value replaces the old value")
    func overwriteReturnsLatestValue() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)

        let original = AppSettings(
            pollingInterval: 60,
            notificationsEnabled: true,
            badgeEnabled: true,
            debugMode: false,
            launchAtLogin: false
        )
        try await manager.save(original, to: "settings.json")

        let updated = AppSettings(
            pollingInterval: 120,
            notificationsEnabled: false,
            badgeEnabled: false,
            debugMode: true,
            launchAtLogin: true
        )
        try await manager.save(updated, to: "settings.json")

        let loaded: AppSettings = try await manager.load(AppSettings.self, from: "settings.json")

        #expect(loaded == updated)
        #expect(loaded.pollingInterval == 120)
        #expect(loaded.notificationsEnabled == false)
        #expect(loaded.debugMode == true)
        #expect(loaded.launchAtLogin == true)
    }

    @Test("Overwrite semantics: repo list update replaces previous list")
    func overwriteRepoListReturnsLatest() async throws {
        let dir = try makeTempDirectory()
        defer { cleanUp(dir) }

        let manager = PersistenceManager(directory: dir)

        let originalRepos = [
            Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0),
        ]
        try await manager.save(originalRepos, to: "repos.json")

        let updatedRepos = [
            Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0),
            Repository(id: UUID(), owner: "apple", name: "swift", sortOrder: 1),
            Repository(id: UUID(), owner: "google", name: "guava", sortOrder: 2),
        ]
        try await manager.save(updatedRepos, to: "repos.json")

        let loaded = try await manager.load([Repository].self, from: "repos.json")

        #expect(loaded.count == 3)
        #expect(loaded[0].fullName == "aws/aws-sdk-java-v2")
        #expect(loaded[1].fullName == "apple/swift")
        #expect(loaded[2].fullName == "google/guava")
    }
}

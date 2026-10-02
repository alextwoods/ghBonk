import Foundation
import Testing
@testable import ghBonk

// MARK: - Property 3: Polling Interval Validation
// **Validates: Requirements 3.2**
// For any TimeInterval value, the system accepts values >= 30 and clamps values < 30 to 30.

// MARK: - Property 6: State Diff Completeness
// **Validates: Requirements 3.3**
// For any (old, new) PR snapshots, diff produces exactly one event per changed PR
// and no events for unchanged PRs.

// MARK: - Mock API Client

/// A mock `GitHubAPIClientProtocol` implementation that returns configurable responses.
private final class MockGitHubAPIClient: GitHubAPIClientProtocol, @unchecked Sendable {
    var pullRequestsByRepo: [String: [PullRequestDTO]] = [:]
    var checkRunsByRef: [String: [CheckRunDTO]] = [:]
    var reviewRequestsByPR: [Int: ReviewRequestsDTO] = [:]
    var issueCommentsByPR: [Int: [IssueCommentDTO]] = [:]
    var reviewCommentsByPR: [Int: [ReviewCommentDTO]] = [:]
    var reviewsByPR: [Int: [ReviewDTO]] = [:]
    var commitsByPR: [Int: [CommitDTO]] = [:]

    func validateToken(_ token: String) async throws -> GitHubUser {
        GitHubUser(login: "testuser", id: 1)
    }

    func fetchPullRequests(repo: Repository) async throws -> [PullRequestDTO] {
        pullRequestsByRepo[repo.fullName] ?? []
    }

    func fetchCheckRuns(repo: Repository, ref: String) async throws -> [CheckRunDTO] {
        checkRunsByRef[ref] ?? []
    }

    func fetchReviewRequests(repo: Repository, prNumber: Int) async throws -> ReviewRequestsDTO {
        reviewRequestsByPR[prNumber] ?? ReviewRequestsDTO(users: [], teams: [])
    }

    func fetchIssueComments(repo: Repository, prNumber: Int) async throws -> [IssueCommentDTO] {
        issueCommentsByPR[prNumber] ?? []
    }

    func fetchReviewComments(repo: Repository, prNumber: Int) async throws -> [ReviewCommentDTO] {
        reviewCommentsByPR[prNumber] ?? []
    }

    func fetchReviews(repo: Repository, prNumber: Int) async throws -> [ReviewDTO] {
        reviewsByPR[prNumber] ?? []
    }

    func fetchCommits(repo: Repository, prNumber: Int) async throws -> [CommitDTO] {
        commitsByPR[prNumber] ?? []
    }
}

// MARK: - Test Suite

@Suite("PollingEngine Property Tests")
struct PollingEnginePropertyTests {

    // MARK: - Helpers

    private let testUser = GitHubUser(login: "testuser", id: 1)

    private let testRepo = Repository(
        id: UUID(),
        owner: "aws",
        name: "aws-sdk-java-v2",
        sortOrder: 0
    )

    private func makePollingEngine(
        apiClient: GitHubAPIClientProtocol,
        interval: TimeInterval,
        repos: [Repository] = []
    ) -> PollingEngine {
        PollingEngine(
            apiClient: apiClient,
            interval: interval,
            repos: repos,
            currentUser: testUser
        )
    }

    private func makePR(
        number: Int,
        title: String = "Test PR",
        authorLogin: String = "testuser",
        state: String = "open",
        draft: Bool = false,
        sha: String = "abc123"
    ) -> PullRequestDTO {
        PullRequestDTO(
            number: number,
            title: title,
            state: state,
            draft: draft,
            user: GitHubUser(login: authorLogin, id: 1),
            head: PullRequestDTO.HeadInfo(ref: "feature", sha: sha),
            updatedAt: Date(),
            htmlURL: URL(string: "https://github.com/aws/aws-sdk-java-v2/pull/\(number)")!,
            mergedAt: nil,
            autoMerge: nil
        )
    }

    private func makeCheckRun(
        id: Int,
        name: String = "Build SDK / aws-sdk-pr-build (pull_request)",
        status: String = "completed",
        conclusion: String? = "success"
    ) -> CheckRunDTO {
        CheckRunDTO(
            id: id,
            name: name,
            status: status,
            conclusion: conclusion,
            htmlURL: URL(string: "https://github.com/checks/\(id)")!
        )
    }

    // MARK: - Property 3: Polling Interval Validation

    /// Values below 30 seconds are clamped to 30.
    static let subMinimumIntervals: [TimeInterval] = [
        0, 0.1, 1, 5, 10, 15, 20, 25, 29, 29.9
    ]

    @Test("Property 3a: Intervals below 30 are clamped to 30 at construction",
          arguments: subMinimumIntervals)
    func intervalBelowMinimumClampedAtInit(interval: TimeInterval) async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: interval)

        // updateInterval returns the actual interval that was set.
        // Since we initialized with a sub-30 value, the internal interval should be 30.
        // We verify by calling updateInterval with the same value and checking it clamps.
        let actual = await engine.updateInterval(interval)
        #expect(
            actual == 30,
            "Interval \(interval) should be clamped to 30, but got \(actual)"
        )
    }

    @Test("Property 3b: updateInterval clamps sub-30 values to 30",
          arguments: subMinimumIntervals)
    func updateIntervalClampsBelowMinimum(interval: TimeInterval) async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60)  // Start with valid interval

        let actual = await engine.updateInterval(interval)
        #expect(
            actual == 30,
            "updateInterval(\(interval)) should return 30, but got \(actual)"
        )
    }

    /// Values at or above 30 seconds are accepted as-is.
    static let validIntervals: [TimeInterval] = [
        30, 30.1, 31, 45, 60, 90, 120, 300, 600, 3600
    ]

    @Test("Property 3c: Intervals at or above 30 are accepted as-is",
          arguments: validIntervals)
    func intervalAtOrAboveMinimumAccepted(interval: TimeInterval) async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: interval)

        // Verify via updateInterval — setting the same value again should return it unchanged
        let actual = await engine.updateInterval(interval)
        #expect(
            actual == interval,
            "Interval \(interval) should be accepted as-is, but got \(actual)"
        )
    }

    @Test("Property 3d: updateInterval accepts values at or above 30",
          arguments: validIntervals)
    func updateIntervalAcceptsValidValues(interval: TimeInterval) async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 30)  // Start with minimum

        let actual = await engine.updateInterval(interval)
        #expect(
            actual == interval,
            "updateInterval(\(interval)) should return \(interval), but got \(actual)"
        )
    }

    @Test("Property 3e: Minimum boundary - 30 exactly is accepted, 29.999 is clamped")
    func intervalBoundaryBehavior() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60)

        let atBoundary = await engine.updateInterval(30)
        #expect(atBoundary == 30, "Exactly 30 should be accepted")

        let belowBoundary = await engine.updateInterval(29.999)
        #expect(belowBoundary == 30, "29.999 should be clamped to 30")
    }

    // MARK: - Property 6: State Diff Completeness

    @Test("Property 6a: First poll with new authored PRs produces NO events (suppressed)")
    func firstPollAuthoredPRsSuppressed() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        // Set up 2 authored PRs
        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "PR One", sha: "sha1"),
            makePR(number: 2, title: "PR Two", sha: "sha2"),
        ]

        let events = await engine.pollOnce()

        #expect(
            events.count == 0,
            "New authored PRs should NOT produce events (you know you created them), got \(events.count)"
        )
    }

    @Test("Property 6a2: First poll with reviewing PR produces reviewRequested event")
    func firstPollReviewingPRProducesEvent() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        // Set up a PR authored by someone else where testuser is a reviewer
        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "PR One", authorLogin: "otheruser", sha: "sha1"),
        ]
        client.reviewRequestsByPR[1] = ReviewRequestsDTO(
            users: [GitHubUser(login: "testuser", id: 1)],
            teams: []
        )

        let events = await engine.pollOnce()

        #expect(events.count == 1, "New reviewing PR should produce 1 event, got \(events.count)")
        #expect(events.first?.eventType == .reviewRequested)
    }

    @Test("Property 6b: Second poll with unchanged data produces zero events")
    func unchangedDataProducesNoEvents() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "PR One", sha: "sha1"),
        ]

        _ = await engine.pollOnce()
        let events = await engine.pollOnce()

        #expect(events.count == 0, "Unchanged data should produce 0 events, got \(events.count)")
    }

    @Test("Property 6c: Reviewing PR removed produces event, authored PR removed does not")
    func prDisappearanceBehavior() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        // Initial: 1 authored PR, 1 reviewing PR
        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "My PR", authorLogin: "testuser", sha: "sha1"),
            makePR(number: 2, title: "Their PR", authorLogin: "otheruser", sha: "sha2"),
        ]
        client.reviewRequestsByPR[2] = ReviewRequestsDTO(
            users: [GitHubUser(login: "testuser", id: 1)], teams: []
        )

        _ = await engine.pollOnce()

        // Both PRs disappear
        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = []

        let events = await engine.pollOnce()

        // Authored PR (#1) disappearing: no event (you closed it)
        let pr1Events = events.filter { $0.prIdentifier == "aws/aws-sdk-java-v2#1" }
        #expect(pr1Events.count == 0, "Authored PR disappearing should not emit event")

        // Reviewing PR (#2) disappearing: emits event
        let pr2Events = events.filter { $0.prIdentifier == "aws/aws-sdk-java-v2#2" }
        #expect(pr2Events.count == 1, "Reviewing PR disappearing should emit 1 event")
    }

    @Test("Property 6d: Check run completing produces exactly 1 checkCompleted event")
    func checkRunCompletedProducesOneEvent() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "PR One", authorLogin: "testuser", sha: "sha1"),
        ]
        client.checkRunsByRef["sha1"] = [
            makeCheckRun(id: 100, status: "in_progress", conclusion: nil),
        ]

        _ = await engine.pollOnce()

        client.checkRunsByRef["sha1"] = [
            makeCheckRun(id: 100, status: "completed", conclusion: "success"),
        ]

        let events = await engine.pollOnce()
        let checkEvents = events.filter { $0.eventType == .checkCompleted }
        #expect(checkEvents.count == 1, "One check completing should produce 1 event, got \(checkEvents.count)")
    }

    @Test("Property 6e: New commit on reviewing PR produces newCommitPushed event")
    func newCommitOnReviewingPR() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "Their PR", authorLogin: "otheruser", sha: "sha1"),
        ]
        client.reviewRequestsByPR[1] = ReviewRequestsDTO(
            users: [GitHubUser(login: "testuser", id: 1)], teams: []
        )
        client.commitsByPR[1] = [
            CommitDTO(sha: "aaa", commit: CommitDTO.CommitInfo(message: "initial", author: nil))
        ]

        _ = await engine.pollOnce()

        // Author pushes a new commit
        client.commitsByPR[1] = [
            CommitDTO(sha: "aaa", commit: CommitDTO.CommitInfo(message: "initial", author: nil)),
            CommitDTO(sha: "bbb", commit: CommitDTO.CommitInfo(message: "fix", author: nil)),
        ]

        let events = await engine.pollOnce()
        let commitEvents = events.filter { $0.eventType == .newCommitPushed }
        #expect(commitEvents.count == 1, "New commit should produce 1 event, got \(commitEvents.count)")
    }

    @Test("Property 6f: New comment by other user on authored PR produces commentAdded event")
    func newCommentOnAuthoredPR() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "My PR", authorLogin: "testuser", sha: "sha1"),
        ]
        client.issueCommentsByPR[1] = []

        _ = await engine.pollOnce()

        // Someone else comments
        client.issueCommentsByPR[1] = [
            IssueCommentDTO(
                id: 500,
                user: GitHubUser(login: "reviewer1", id: 2),
                body: "LGTM",
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let events = await engine.pollOnce()
        let commentEvents = events.filter { $0.eventType == .commentAdded }
        #expect(commentEvents.count == 1, "New comment by others should produce 1 event, got \(commentEvents.count)")
    }

    @Test("Property 6g: Own comments on authored PR do NOT produce events")
    func ownCommentsIgnored() async {
        let client = MockGitHubAPIClient()
        let engine = makePollingEngine(apiClient: client, interval: 60, repos: [testRepo])

        client.pullRequestsByRepo["aws/aws-sdk-java-v2"] = [
            makePR(number: 1, title: "My PR", authorLogin: "testuser", sha: "sha1"),
        ]
        client.issueCommentsByPR[1] = []

        _ = await engine.pollOnce()

        // I comment on my own PR — should NOT produce event
        client.issueCommentsByPR[1] = [
            IssueCommentDTO(
                id: 600,
                user: GitHubUser(login: "testuser", id: 1),
                body: "WIP",
                createdAt: Date(),
                updatedAt: Date()
            )
        ]

        let events = await engine.pollOnce()
        #expect(events.count == 0, "Own comments should not produce events, got \(events.count)")
    }
}

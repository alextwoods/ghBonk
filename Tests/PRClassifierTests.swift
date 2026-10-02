import Foundation
import Testing
@testable import ghBonk

// MARK: - PRClassifier Unit Tests
// **Validates: Requirements 3.6, 3.7**

@Suite("PRClassifier Tests")
struct PRClassifierTests {

    // MARK: - Helpers

    private func makeUser(login: String, id: Int = 1) -> GitHubUser {
        GitHubUser(login: login, id: id)
    }

    private func makePR(authorLogin: String) -> PullRequestDTO {
        PullRequestDTO(
            number: 42,
            title: "Test PR",
            state: "open",
            draft: false,
            user: makeUser(login: authorLogin),
            head: PullRequestDTO.HeadInfo(ref: "feature-branch", sha: "abc123"),
            updatedAt: Date(),
            htmlURL: URL(string: "https://github.com/org/repo/pull/42")!,
            mergedAt: nil,
            autoMerge: nil
        )
    }

    private func makeReviewRequests(
        users: [GitHubUser] = [],
        teams: [GitHubTeam] = []
    ) -> ReviewRequestsDTO {
        ReviewRequestsDTO(users: users, teams: teams)
    }

    // MARK: - Authored Classification

    @Test("Returns .authored when PR author matches current user")
    func classifiesAsAuthored() {
        let currentUser = makeUser(login: "alice")
        let pr = makePR(authorLogin: "alice")
        let reviewRequests = makeReviewRequests()

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == .authored)
    }

    @Test("Authored takes precedence over reviewing (self-review)")
    func authoredPrecedesReviewing() {
        let currentUser = makeUser(login: "alice")
        let pr = makePR(authorLogin: "alice")
        // User is both the author AND assigned as a direct reviewer
        let reviewRequests = makeReviewRequests(users: [makeUser(login: "alice")])

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == .authored)
    }

    // MARK: - Reviewing Classification

    @Test("Returns .reviewing when user is a direct reviewer")
    func classifiesAsReviewing() {
        let currentUser = makeUser(login: "bob")
        let pr = makePR(authorLogin: "alice")
        let reviewRequests = makeReviewRequests(users: [makeUser(login: "bob")])

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == .reviewing)
    }

    @Test("Returns .reviewing when user is among multiple direct reviewers")
    func classifiesAsReviewingAmongMultiple() {
        let currentUser = makeUser(login: "bob")
        let pr = makePR(authorLogin: "alice")
        let reviewRequests = makeReviewRequests(users: [
            makeUser(login: "charlie"),
            makeUser(login: "bob"),
            makeUser(login: "dave"),
        ])

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == .reviewing)
    }

    // MARK: - Team-Based Exclusion

    @Test("Returns nil when user is only assigned via team (not direct user assignment)")
    func teamAssignmentExcluded() {
        let currentUser = makeUser(login: "bob")
        let pr = makePR(authorLogin: "alice")
        // User is on a team that's assigned, but NOT in the direct users list
        let reviewRequests = makeReviewRequests(
            users: [],
            teams: [GitHubTeam(slug: "core-team", name: "Core Team")]
        )

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == nil)
    }

    @Test("Returns .reviewing when user is directly assigned even if teams are also assigned")
    func directAssignmentWithTeamsPresent() {
        let currentUser = makeUser(login: "bob")
        let pr = makePR(authorLogin: "alice")
        // Both direct user assignment AND team assignment exist
        let reviewRequests = makeReviewRequests(
            users: [makeUser(login: "bob")],
            teams: [GitHubTeam(slug: "core-team", name: "Core Team")]
        )

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == .reviewing)
    }

    // MARK: - Nil (Irrelevant) Classification

    @Test("Returns nil when user is neither author nor reviewer")
    func classifiesAsIrrelevant() {
        let currentUser = makeUser(login: "eve")
        let pr = makePR(authorLogin: "alice")
        let reviewRequests = makeReviewRequests(users: [makeUser(login: "bob")])

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == nil)
    }

    @Test("Returns nil with empty review requests and different author")
    func classifiesAsIrrelevantEmpty() {
        let currentUser = makeUser(login: "eve")
        let pr = makePR(authorLogin: "alice")
        let reviewRequests = makeReviewRequests()

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        #expect(result == nil)
    }

    // MARK: - Case Sensitivity

    @Test("Login comparison is case-sensitive")
    func loginComparisonIsCaseSensitive() {
        let currentUser = makeUser(login: "Alice")
        let pr = makePR(authorLogin: "alice")
        let reviewRequests = makeReviewRequests()

        let result = PRClassifier.classify(pr: pr, reviewRequests: reviewRequests, currentUser: currentUser)

        // GitHub logins are case-insensitive in practice, but the API returns
        // consistent casing so exact string match is correct here.
        #expect(result == nil)
    }
}

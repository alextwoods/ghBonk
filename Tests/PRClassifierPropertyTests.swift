import Foundation
import Testing
@testable import ghBonk

// MARK: - Property 5: PR Classification Correctness
// **Validates: Requirements 3.6, 3.7**
// For any (PR, reviewRequests, user) triple, classification follows the
// authored/reviewing/nil rules exactly.

@Suite("PRClassifier Property Tests")
struct PRClassifierPropertyTests {

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

    /// Generates a list of reviewer users (excluding the given login).
    private func makeOtherReviewers(count: Int, excluding login: String) -> [GitHubUser] {
        (0..<count).map { i in
            GitHubUser(login: "reviewer-\(i)", id: 100 + i)
        }
    }

    /// Generates a list of teams.
    private func makeTeams(count: Int) -> [GitHubTeam] {
        (0..<count).map { i in
            GitHubTeam(slug: "team-\(i)", name: "Team \(i)")
        }
    }

    // MARK: - Property 1: Authored Property
    // For any PR where pr.user.login == currentUser.login, regardless of what's
    // in reviewRequests, the result should always be .authored.

    /// Argument set: (number of other reviewers, number of teams, user is also in reviewers list)
    static let authoredArguments: [(Int, Int, Bool)] = [
        (0, 0, false),   // no reviewers, no teams
        (1, 0, false),   // one other reviewer, no teams
        (3, 0, false),   // multiple other reviewers, no teams
        (0, 1, false),   // no reviewers, one team
        (0, 3, false),   // no reviewers, multiple teams
        (2, 2, false),   // mix of other reviewers and teams
        (5, 5, false),   // many other reviewers and teams
        (0, 0, true),    // user is also in reviewer list (self-review)
        (1, 0, true),    // user in reviewer list with one other
        (3, 2, true),    // user in reviewer list with others and teams
        (0, 4, true),    // user in reviewer list with only teams
    ]

    @Test(
        "Authored: PR author == currentUser always returns .authored",
        arguments: authoredArguments
    )
    func authoredProperty(
        otherReviewerCount: Int,
        teamCount: Int,
        userAlsoReviewer: Bool
    ) {
        let currentUser = makeUser(login: "the-author")
        let pr = makePR(authorLogin: "the-author")

        var reviewerUsers = makeOtherReviewers(count: otherReviewerCount, excluding: "the-author")
        if userAlsoReviewer {
            reviewerUsers.append(makeUser(login: "the-author"))
        }
        let teams = makeTeams(count: teamCount)
        let reviewRequests = makeReviewRequests(users: reviewerUsers, teams: teams)

        let result = PRClassifier.classify(
            pr: pr,
            reviewRequests: reviewRequests,
            currentUser: currentUser
        )

        #expect(result == .authored,
            "Expected .authored when pr.user.login == currentUser.login (otherReviewers=\(otherReviewerCount), teams=\(teamCount), selfReview=\(userAlsoReviewer))")
    }

    // MARK: - Property 2: Reviewing Property
    // For any PR where pr.user.login != currentUser.login AND currentUser.login
    // is in reviewRequests.users, the result should be .reviewing.

    /// Argument set: (position of current user in users list, total reviewers, number of teams)
    static let reviewingArguments: [(Int, Int, Int)] = [
        (0, 1, 0),   // sole reviewer, no teams
        (0, 3, 0),   // first in list of 3
        (1, 3, 0),   // middle of list of 3
        (2, 3, 0),   // last in list of 3
        (0, 1, 1),   // sole reviewer, one team
        (0, 1, 3),   // sole reviewer, multiple teams
        (2, 5, 2),   // mixed position, moderate lists
        (4, 5, 0),   // last in longer list
        (0, 5, 5),   // first in list with many teams
        (3, 7, 3),   // arbitrary position in longer list
    ]

    @Test(
        "Reviewing: user in reviewRequests.users (not author) returns .reviewing",
        arguments: reviewingArguments
    )
    func reviewingProperty(
        userPosition: Int,
        totalReviewers: Int,
        teamCount: Int
    ) {
        let currentUser = makeUser(login: "the-reviewer")
        let pr = makePR(authorLogin: "different-author")

        // Build reviewer list with current user at the specified position
        var reviewerUsers: [GitHubUser] = []
        for i in 0..<totalReviewers {
            if i == userPosition {
                reviewerUsers.append(makeUser(login: "the-reviewer"))
            } else {
                reviewerUsers.append(GitHubUser(login: "other-\(i)", id: 200 + i))
            }
        }
        let teams = makeTeams(count: teamCount)
        let reviewRequests = makeReviewRequests(users: reviewerUsers, teams: teams)

        let result = PRClassifier.classify(
            pr: pr,
            reviewRequests: reviewRequests,
            currentUser: currentUser
        )

        #expect(result == .reviewing,
            "Expected .reviewing when user is at position \(userPosition)/\(totalReviewers) in reviewRequests.users (teams=\(teamCount))")
    }

    // MARK: - Property 3: Nil Property
    // For any PR where pr.user.login != currentUser.login AND currentUser.login
    // is NOT in reviewRequests.users (even if teams are present), the result should be nil.

    /// Argument set: (number of other reviewers, number of teams)
    static let nilArguments: [(Int, Int)] = [
        (0, 0),   // empty: no reviewers, no teams
        (1, 0),   // other reviewers only
        (3, 0),   // multiple other reviewers
        (0, 1),   // only teams assigned
        (0, 3),   // multiple teams only
        (2, 1),   // mix of other reviewers and teams
        (0, 5),   // many teams
        (5, 0),   // many other reviewers
        (5, 5),   // many of both
        (10, 10), // large lists
    ]

    @Test(
        "Nil: user is neither author nor direct reviewer returns nil",
        arguments: nilArguments
    )
    func nilProperty(
        otherReviewerCount: Int,
        teamCount: Int
    ) {
        let currentUser = makeUser(login: "irrelevant-user")
        let pr = makePR(authorLogin: "some-author")

        // Ensure current user is NOT in the reviewer users list
        let reviewerUsers = makeOtherReviewers(count: otherReviewerCount, excluding: "irrelevant-user")
        let teams = makeTeams(count: teamCount)
        let reviewRequests = makeReviewRequests(users: reviewerUsers, teams: teams)

        let result = PRClassifier.classify(
            pr: pr,
            reviewRequests: reviewRequests,
            currentUser: currentUser
        )

        #expect(result == nil,
            "Expected nil when user is not author and not in reviewRequests.users (otherReviewers=\(otherReviewerCount), teams=\(teamCount))")
    }

    // MARK: - Property 4: Authored Precedence
    // When both authored AND reviewing conditions are met, authored always wins.

    /// Argument set: (position of author-user in reviewers list, total reviewers, number of teams)
    static let precedenceArguments: [(Int, Int, Int)] = [
        (0, 1, 0),   // sole reviewer
        (0, 3, 0),   // first among reviewers
        (1, 3, 0),   // middle of reviewers
        (2, 3, 0),   // last among reviewers
        (0, 1, 2),   // with teams
        (0, 5, 5),   // large lists, first position
        (4, 5, 3),   // large lists, last position
        (2, 5, 0),   // middle of larger list, no teams
    ]

    @Test(
        "Authored precedence: author + direct reviewer always returns .authored",
        arguments: precedenceArguments
    )
    func authoredPrecedenceProperty(
        userPosition: Int,
        totalReviewers: Int,
        teamCount: Int
    ) {
        let currentUser = makeUser(login: "dual-role-user")
        let pr = makePR(authorLogin: "dual-role-user")

        // User is BOTH the PR author AND directly assigned as a reviewer
        var reviewerUsers: [GitHubUser] = []
        for i in 0..<totalReviewers {
            if i == userPosition {
                reviewerUsers.append(makeUser(login: "dual-role-user"))
            } else {
                reviewerUsers.append(GitHubUser(login: "other-reviewer-\(i)", id: 300 + i))
            }
        }
        let teams = makeTeams(count: teamCount)
        let reviewRequests = makeReviewRequests(users: reviewerUsers, teams: teams)

        let result = PRClassifier.classify(
            pr: pr,
            reviewRequests: reviewRequests,
            currentUser: currentUser
        )

        #expect(result == .authored,
            "Expected .authored to take precedence over .reviewing (position=\(userPosition)/\(totalReviewers), teams=\(teamCount))")
    }
}

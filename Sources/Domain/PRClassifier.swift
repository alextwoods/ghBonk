import Foundation

// MARK: - PR Classifier

/// Classifies a pull request as authored, reviewing, or irrelevant for the given user.
///
/// Classification rules:
/// - `authored`: The PR author matches the current user (takes precedence over reviewing).
/// - `reviewing`: The current user is directly assigned as a pending reviewer,
///    OR has previously submitted a review on this PR (so it stays tracked after reviewing).
/// - `nil`: Neither condition holds — the PR is not relevant to this user.
struct PRClassifier {
    /// Classifies using only pending review requests (legacy, used by tests).
    static func classify(
        pr: PullRequestDTO,
        reviewRequests: ReviewRequestsDTO,
        currentUser: GitHubUser
    ) -> PRRole? {
        return classify(pr: pr, reviewRequests: reviewRequests, reviews: [], currentUser: currentUser)
    }

    /// Classifies using both pending review requests and submitted reviews.
    /// A user is considered a reviewer if they are a pending direct reviewer OR
    /// have previously submitted a review (not via team assignment).
    static func classify(
        pr: PullRequestDTO,
        reviewRequests: ReviewRequestsDTO,
        reviews: [ReviewDTO],
        currentUser: GitHubUser
    ) -> PRRole? {
        if pr.user.login == currentUser.login {
            return .authored
        }

        // Check pending direct reviewer assignment
        let isPendingReviewer = reviewRequests.users.contains { $0.login == currentUser.login }
        if isPendingReviewer {
            return .reviewing
        }

        // Check if user has previously submitted a review on this PR
        let hasReviewed = reviews.contains { $0.user.login == currentUser.login }
        if hasReviewed {
            return .reviewing
        }

        return nil
    }
}
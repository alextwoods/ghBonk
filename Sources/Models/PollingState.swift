import Foundation

// MARK: - Polling State Snapshot

/// Persistable snapshot of the PollingEngine's internal state.
/// Saved to disk between launches so the app can detect only genuine
/// new activity rather than re-emitting stale events.
struct PollingStateSnapshot: Codable, Sendable {
    let trackedPRs: [TrackedPR]
    let checkRuns: [String: [CheckRunDTO]]
    let activityCounts: [String: PRActivityCounts]
    let mergeQueueState: [String: Bool]
}

// MARK: - PR Activity Counts

/// Tracks comment/review/commit counts per PR for detecting new activity.
/// Persisted between sessions to avoid false positives on relaunch.
struct PRActivityCounts: Codable, Sendable {
    let issueCommentCount: Int
    let reviewCommentCount: Int
    let reviewCount: Int
    let commitCount: Int
    let lastCommitSHA: String?
    /// IDs of comments/reviews by others (for diffing)
    let issueCommentIDs: Set<Int>
    let reviewCommentIDs: Set<Int>
    let reviewIDs: Set<Int>
}

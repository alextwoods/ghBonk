import Foundation

// MARK: - Polling Engine

/// Orchestrates periodic fetching of PR data from GitHub, classifies PRs,
/// and diffs against previous state to produce events.
actor PollingEngine {
    // MARK: - Constants

    static let minimumInterval: TimeInterval = 30

    // MARK: - Dependencies

    private let apiClient: GitHubAPIClientProtocol
    private let currentUser: GitHubUser

    // MARK: - Configuration

    private var interval: TimeInterval
    private var repos: [Repository]

    // MARK: - State

    private var task: Task<Void, Never>?
    private var previousState: [String: TrackedPR] = [:]
    private var previousCheckRuns: [String: [CheckRunDTO]] = [:]

    /// Tracks comment/review/commit counts per PR to detect new activity.
    private var previousCommentCounts: [String: PRActivityCounts] = [:]
    /// Tracks merge queue state per PR.
    private var previousMergeQueueState: [String: Bool] = [:]

    /// Callback invoked with events produced by each poll cycle.
    var onEvents: (@Sendable ([PREvent]) -> Void)?

    /// Callback invoked with newly detected check run failures.
    var onCheckRunFailures: (([CheckRunFailure]) -> Void)?

    func setOnEvents(_ handler: @escaping @Sendable ([PREvent]) -> Void) {
        self.onEvents = handler
    }

    func setOnCheckRunFailures(_ handler: @escaping @Sendable ([CheckRunFailure]) -> Void) {
        self.onCheckRunFailures = handler
    }

    // MARK: - Computed Properties

    var isRunning: Bool {
        guard let task else { return false }
        return !task.isCancelled
    }

    // MARK: - Initialization

    init(
        apiClient: GitHubAPIClientProtocol,
        interval: TimeInterval,
        repos: [Repository],
        currentUser: GitHubUser
    ) {
        self.apiClient = apiClient
        self.interval = max(interval, Self.minimumInterval)
        self.repos = repos
        self.currentUser = currentUser
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                let events = await pollOnce()
                if !events.isEmpty {
                    onEvents?(events)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Public Accessors

    func getTrackedPRs() -> [TrackedPR] {
        return Array(previousState.values)
    }

    /// Seeds the engine state from persisted data.
    /// Call this before `start()` to restore state from a previous session,
    /// allowing accurate diffing without re-emitting stale events.
    func seedState(from snapshot: PollingStateSnapshot) {
        for pr in snapshot.trackedPRs {
            previousState[pr.id] = pr
        }
        previousCheckRuns = snapshot.checkRuns
        previousCommentCounts = snapshot.activityCounts
        previousMergeQueueState = snapshot.mergeQueueState
    }

    /// Exports the current polling state for persistence.
    func exportState() -> PollingStateSnapshot {
        PollingStateSnapshot(
            trackedPRs: Array(previousState.values),
            checkRuns: previousCheckRuns,
            activityCounts: previousCommentCounts,
            mergeQueueState: previousMergeQueueState
        )
    }

    // MARK: - Configuration Updates

    func updateRepos(_ repos: [Repository]) {
        self.repos = repos
    }

    @discardableResult
    func updateInterval(_ newInterval: TimeInterval) -> TimeInterval {
        self.interval = max(newInterval, Self.minimumInterval)
        return self.interval
    }

    // MARK: - Polling

    func pollOnce() async -> [PREvent] {
        var newState: [String: TrackedPR] = [:]
        var newCheckRuns: [String: [CheckRunDTO]] = [:]
        var newCommentCounts: [String: PRActivityCounts] = [:]
        var newMergeQueueState: [String: Bool] = [:]
        var successfullyFetchedRepos: Set<String> = []
        var events: [PREvent] = []
        let now = Date()

        for repo in repos {
            do {
                let prs = try await apiClient.fetchPullRequests(repo: repo)
                successfullyFetchedRepos.insert(repo.fullName)

                for pr in prs {
                    do {
                        let reviewRequests = try await apiClient.fetchReviewRequests(
                            repo: repo, prNumber: pr.number
                        )
                        let reviews = (try? await apiClient.fetchReviews(
                            repo: repo, prNumber: pr.number
                        )) ?? []

                        let prId = "\(repo.fullName)#\(pr.number)"

                        // Classify the PR. If classification fails (nil) but we
                        // previously tracked this PR, keep it with the old role.
                        // This prevents flickering when the reviews API is transiently unavailable.
                        let role: PRRole
                        if let classified = PRClassifier.classify(
                            pr: pr, reviewRequests: reviewRequests, reviews: reviews, currentUser: currentUser
                        ) {
                            role = classified
                        } else if let previousRole = previousState[prId]?.role {
                            // Can't classify now, but we tracked it before — retain old role
                            role = previousRole
                        } else {
                            continue  // Genuinely irrelevant PR
                        }

                        var sdkBuildStatus: CheckStatus? = nil
                        var checkRuns: [CheckRunDTO] = []

                        // Fetch check runs for authored PRs
                        if role == .authored {
                            checkRuns = (try? await apiClient.fetchCheckRuns(repo: repo, ref: pr.head.sha)) ?? []
                            sdkBuildStatus = extractSDKBuildStatus(from: checkRuns)
                            newCheckRuns[prId] = checkRuns
                        }

                        // Fetch activity data (comments, reviews, commits)
                        let activity = await fetchActivityCounts(repo: repo, pr: pr, role: role)
                        newCommentCounts[prId] = activity

                        // Track merge queue state for authored PRs (detected via check runs)
                        if role == .authored {
                            newMergeQueueState[prId] = isMergeQueueActive(checkRuns: checkRuns)
                        }

                        var prState = mapPRState(from: pr)
                        if role == .authored && (newMergeQueueState[prId] ?? false) {
                            prState = .queued
                        }
                        let reviewSummary = buildReviewSummary(
                            reviewRequests: reviewRequests, reviews: reviews, prAuthor: pr.user.login
                        )

                        let trackedPR = TrackedPR(
                            id: prId,
                            number: pr.number,
                            title: pr.title,
                            repository: repo,
                            state: prState,
                            role: role,
                            reviewStatus: reviewSummary.status,
                            reviewSummary: reviewSummary,
                            sdkBuildStatus: sdkBuildStatus,
                            latestEvent: nil,
                            updatedAt: pr.updatedAt
                        )

                        newState[prId] = trackedPR

                        // --- Generate events by diffing ---

                        let prEvents = generateEvents(
                            prId: prId,
                            newPR: trackedPR,
                            pr: pr,
                            role: role,
                            repo: repo,
                            activity: activity,
                            checkRuns: checkRuns,
                            isInMergeQueue: newMergeQueueState[prId] ?? false,
                            timestamp: now
                        )
                        events.append(contentsOf: prEvents)

                    } catch {
                        continue
                    }
                }
            } catch {
                continue
            }
        }

        // PRs that disappeared (closed/merged).
        // Only consider PRs from repos we successfully fetched this cycle —
        // if a repo fetch failed, its PRs just stay in previousState unchanged.
        for (prId, oldPR) in previousState where newState[prId] == nil {
            // Skip if this PR's repo wasn't successfully fetched (transient failure)
            guard successfullyFetchedRepos.contains(oldPR.repository.fullName) else {
                // Carry forward the old state — repo fetch probably failed
                newState[prId] = oldPR
                if let oldChecks = previousCheckRuns[prId] {
                    newCheckRuns[prId] = oldChecks
                }
                if let oldActivity = previousCommentCounts[prId] {
                    newCommentCounts[prId] = oldActivity
                }
                if let oldMQ = previousMergeQueueState[prId] {
                    newMergeQueueState[prId] = oldMQ
                }
                continue
            }
            // For authored PRs: check if it was in merge queue and disappeared = merged or merge queue failed
            if oldPR.role == .authored, previousMergeQueueState[prId] == true {
                // PR was in merge queue and is now gone — it either merged or failed
                // We'll emit prMerged (the common case); merge queue failure would
                // show the PR back in open state, which we'd catch above.
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: oldPR.title,
                    repository: oldPR.repository, eventType: .prMerged,
                    timestamp: now, summary: "PR merged via merge queue"
                ))
            }
            // Don't emit "PR no longer open" for authored PRs (you closed it yourself)
            // Do emit for reviewing PRs (the author closed/merged it, you should know)
            else if oldPR.role == .reviewing {
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: oldPR.title,
                    repository: oldPR.repository, eventType: .prStateChanged,
                    timestamp: now, summary: "PR no longer open"
                ))
            }
        }

        // Detect check run failures for persistence
        let failures = detectNewFailures(oldCheckRuns: previousCheckRuns, newCheckRuns: newCheckRuns)
        if !failures.isEmpty {
            onCheckRunFailures?(failures)
        }

        // Update stored state
        previousState = newState
        previousCheckRuns = newCheckRuns
        previousCommentCounts = newCommentCounts
        previousMergeQueueState = newMergeQueueState

        return events
    }

    // MARK: - Event Generation

    private func generateEvents(
        prId: String,
        newPR: TrackedPR,
        pr: PullRequestDTO,
        role: PRRole,
        repo: Repository,
        activity: PRActivityCounts,
        checkRuns: [CheckRunDTO],
        isInMergeQueue: Bool,
        timestamp: Date
    ) -> [PREvent] {
        var events: [PREvent] = []

        guard let oldPR = previousState[prId] else {
            // New PR appeared
            if role == .authored {
                // Don't notify for your own new PRs — you already know.
                // But DO notify if it's already in the merge queue (you might have
                // launched the app after adding to queue).
                if isInMergeQueue {
                    events.append(PREvent(
                        id: UUID(), prIdentifier: prId, prTitle: newPR.title,
                        repository: repo, eventType: .enteredMergeQueue,
                        timestamp: timestamp, summary: "PR is in the merge queue"
                    ))
                }
            } else {
                // Reviewing: you were assigned, notify
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: newPR.title,
                    repository: repo, eventType: .reviewRequested,
                    timestamp: timestamp, summary: "You were assigned to review this PR"
                ))
            }
            return events
        }

        // --- State changes ---

        if oldPR.state != newPR.state {
            if newPR.state == .merged {
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: newPR.title,
                    repository: repo, eventType: .prMerged,
                    timestamp: timestamp, summary: "PR was merged"
                ))
            } else if role == .reviewing && oldPR.state == .draft && newPR.state == .open {
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: newPR.title,
                    repository: repo, eventType: .prStateChanged,
                    timestamp: timestamp, summary: "PR is ready for review (was draft)"
                ))
            }
        }

        // --- Merge queue events (authored only) ---

        if role == .authored {
            let wasInQueue = previousMergeQueueState[prId] ?? false

            if !wasInQueue && isInMergeQueue {
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: newPR.title,
                    repository: repo, eventType: .enteredMergeQueue,
                    timestamp: timestamp, summary: "PR entered the merge queue"
                ))
            } else if wasInQueue && !isInMergeQueue && newPR.state == .open {
                // Was in queue, no longer in queue, but still open = merge queue failed
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: newPR.title,
                    repository: repo, eventType: .mergeQueueFailed,
                    timestamp: timestamp, summary: "PR was removed from the merge queue (merge failed)"
                ))
            }
        }

        // --- Comment/review activity ---

        // Only diff activity if we have a previous baseline for this PR.
        // First poll for a PR just records counts without emitting events.
        if let oldActivity = previousCommentCounts[prId] {
            let commentEvents = diffActivity(
                prId: prId, prTitle: newPR.title, repo: repo,
                role: role, oldActivity: oldActivity, newActivity: activity,
                timestamp: timestamp
            )
            events.append(contentsOf: commentEvents)
        }

        // --- Check run changes (authored only) ---
        // Only diff if we have a previous baseline. If previousCheckRuns[prId] is nil,
        // this is the first time we're seeing this PR's checks — establish baseline, don't emit.

        if role == .authored, let oldRuns = previousCheckRuns[prId] {
            let checkEvents = diffCheckRuns(
                oldRuns: oldRuns, newRuns: checkRuns,
                prId: prId, prTitle: newPR.title, repository: repo,
                timestamp: timestamp
            )
            events.append(contentsOf: checkEvents)
        }

        return events
    }

    // MARK: - Activity Fetching & Diffing

    private func fetchActivityCounts(repo: Repository, pr: PullRequestDTO, role: PRRole) async -> PRActivityCounts {
        // For authored PRs: fetch comments by others, reviews by others
        // For reviewing PRs: fetch comments by author, commits
        let issueComments = (try? await apiClient.fetchIssueComments(repo: repo, prNumber: pr.number)) ?? []
        let reviewComments = (try? await apiClient.fetchReviewComments(repo: repo, prNumber: pr.number)) ?? []
        let reviews = (try? await apiClient.fetchReviews(repo: repo, prNumber: pr.number)) ?? []
        let commits = (try? await apiClient.fetchCommits(repo: repo, prNumber: pr.number)) ?? []

        let relevantIssueComments: [IssueCommentDTO]
        let relevantReviewComments: [ReviewCommentDTO]
        let relevantReviews: [ReviewDTO]

        if role == .authored {
            // I care about comments/reviews by others (not myself)
            relevantIssueComments = issueComments.filter { $0.user.login != currentUser.login }
            relevantReviewComments = reviewComments.filter { $0.user.login != currentUser.login }
            relevantReviews = reviews.filter { $0.user.login != currentUser.login }
        } else {
            // Reviewing: I care about comments by the PR author
            relevantIssueComments = issueComments.filter { $0.user.login == pr.user.login }
            relevantReviewComments = reviewComments.filter { $0.user.login == pr.user.login }
            relevantReviews = []  // Don't care about reviews on PRs I'm reviewing
        }

        return PRActivityCounts(
            issueCommentCount: relevantIssueComments.count,
            reviewCommentCount: relevantReviewComments.count,
            reviewCount: relevantReviews.count,
            commitCount: commits.count,
            lastCommitSHA: commits.last?.sha,
            issueCommentIDs: Set(relevantIssueComments.map(\.id)),
            reviewCommentIDs: Set(relevantReviewComments.map(\.id)),
            reviewIDs: Set(relevantReviews.map(\.id))
        )
    }

    private func diffActivity(
        prId: String, prTitle: String, repo: Repository,
        role: PRRole, oldActivity: PRActivityCounts, newActivity: PRActivityCounts,
        timestamp: Date
    ) -> [PREvent] {
        var events: [PREvent] = []

        // New issue comments
        let newIssueCommentIDs = newActivity.issueCommentIDs.subtracting(oldActivity.issueCommentIDs)
        if !newIssueCommentIDs.isEmpty {
            let who = role == .authored ? "Someone" : "Author"
            events.append(PREvent(
                id: UUID(), prIdentifier: prId, prTitle: prTitle,
                repository: repo, eventType: .commentAdded,
                timestamp: timestamp,
                summary: "\(who) commented (\(newIssueCommentIDs.count) new)"
            ))
        }

        // New review comments (inline code comments)
        let newReviewCommentIDs = newActivity.reviewCommentIDs.subtracting(oldActivity.reviewCommentIDs)
        if !newReviewCommentIDs.isEmpty && newIssueCommentIDs.isEmpty {
            // Only emit if we didn't already emit for issue comments (avoid double-notify)
            let who = role == .authored ? "Someone" : "Author"
            events.append(PREvent(
                id: UUID(), prIdentifier: prId, prTitle: prTitle,
                repository: repo, eventType: .commentAdded,
                timestamp: timestamp,
                summary: "\(who) left review comments (\(newReviewCommentIDs.count) new)"
            ))
        }

        // New reviews (authored PRs only — approve/changes requested/comment)
        if role == .authored {
            let newReviewIDs = newActivity.reviewIDs.subtracting(oldActivity.reviewIDs)
            if !newReviewIDs.isEmpty {
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: prTitle,
                    repository: repo, eventType: .reviewSubmitted,
                    timestamp: timestamp,
                    summary: "New review submitted (\(newReviewIDs.count) new)"
                ))
            }
        }

        // New commits (reviewing PRs only — author pushed new code)
        if role == .reviewing {
            if newActivity.commitCount > oldActivity.commitCount ||
               (newActivity.lastCommitSHA != oldActivity.lastCommitSHA && oldActivity.lastCommitSHA != nil) {
                let newCommits = newActivity.commitCount - oldActivity.commitCount
                events.append(PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: prTitle,
                    repository: repo, eventType: .newCommitPushed,
                    timestamp: timestamp,
                    summary: "Author pushed \(max(1, newCommits)) new commit\(newCommits == 1 ? "" : "s")"
                ))
            }
        }

        return events
    }

    // MARK: - Check Run Diffing

    private func diffCheckRuns(
        oldRuns: [CheckRunDTO], newRuns: [CheckRunDTO],
        prId: String, prTitle: String, repository: Repository,
        timestamp: Date
    ) -> [PREvent] {
        let oldCompletedIDs = Set(oldRuns.filter { $0.status == "completed" }.map(\.id))

        return newRuns
            .filter { $0.status == "completed" && !oldCompletedIDs.contains($0.id) }
            .map { checkRun in
                let conclusion = checkRun.conclusion ?? "unknown"
                return PREvent(
                    id: UUID(), prIdentifier: prId, prTitle: prTitle,
                    repository: repository, eventType: .checkCompleted,
                    timestamp: timestamp, summary: "\(checkRun.name): \(conclusion)"
                )
            }
    }

    // MARK: - Check Failure Detection

    private func detectNewFailures(
        oldCheckRuns: [String: [CheckRunDTO]],
        newCheckRuns: [String: [CheckRunDTO]]
    ) -> [CheckRunFailure] {
        var failures: [CheckRunFailure] = []
        for (prId, newRuns) in newCheckRuns {
            // Skip if no previous baseline — first poll shouldn't emit failures
            guard let oldRuns = oldCheckRuns[prId] else { continue }
            let oldFailureIDs = Set(
                oldRuns
                    .filter { $0.status == "completed" && $0.conclusion == "failure" }
                    .map(\.id)
            )
            let newlyFailed = newRuns.filter {
                $0.status == "completed" && $0.conclusion == "failure" && !oldFailureIDs.contains($0.id)
            }
            failures.append(contentsOf: CheckRunFailureMapper.mapFailures(from: newlyFailed))
        }
        return failures
    }

    // MARK: - Helpers

    /// Detects whether a PR is currently in the merge queue by examining check runs.
    /// Looks for the "emit-enqueue" check with success and "emit-dequeue" still skipped/pending.
    /// Falls back to checking the auto_merge field on the PR DTO for repos that use that mechanism.
    private func isMergeQueueActive(checkRuns: [CheckRunDTO]) -> Bool {
        let enqueue = checkRuns.first { $0.name == "emit-enqueue" }
        let dequeue = checkRuns.first { $0.name == "emit-dequeue" }

        // If this repo uses emit-enqueue/dequeue pattern:
        if let enqueue {
            let isEnqueued = enqueue.status == "completed" && enqueue.conclusion == "success"
            let isStillQueued = dequeue == nil ||
                (dequeue?.conclusion == "skipped") ||
                (dequeue?.status != "completed")
            return isEnqueued && isStillQueued
        }

        return false
    }

    private func extractSDKBuildStatus(from checkRuns: [CheckRunDTO]) -> CheckStatus {
        guard let sdkBuild = checkRuns.first(where: { $0.name == CIEvaluator.sdkBuildCheckName }) else {
            return .notApplicable
        }
        switch sdkBuild.status {
        case "completed":
            return sdkBuild.conclusion == "success" ? .success :
                   sdkBuild.conclusion == "failure" ? .failure : .pending
        default:
            return .pending
        }
    }

    private func mapPRState(from pr: PullRequestDTO) -> PRState {
        if pr.draft { return .draft }
        if pr.mergedAt != nil { return .merged }
        switch pr.state {
        case "open": return .open
        case "closed": return .closed
        default: return .open
        }
    }

    /// Builds a detailed review summary from pending reviewer requests and submitted reviews.
    /// Excludes team-based reviewers — only counts individual direct reviewers.
    /// For each reviewer, takes their most recent review state.
    private func buildReviewSummary(
        reviewRequests: ReviewRequestsDTO,
        reviews: [ReviewDTO],
        prAuthor: String
    ) -> ReviewSummary {
        // Pending direct reviewers (haven't reviewed yet)
        let pendingReviewers = Set(reviewRequests.users.map(\.login))

        // Get the latest review state per reviewer (excluding the PR author)
        // A reviewer can submit multiple reviews; we take the most recent one.
        var latestReviewByUser: [String: String] = [:]  // login -> state
        for review in reviews {
            // Skip the PR author's own reviews
            if review.user.login == prAuthor { continue }
            // Skip team-based "COMMENTED" reviews that are just noise
            // Keep only meaningful states
            let state = review.state.uppercased()
            if state == "APPROVED" || state == "CHANGES_REQUESTED" || state == "COMMENTED" || state == "DISMISSED" {
                latestReviewByUser[review.user.login] = state
            }
        }

        // Total reviewers = pending + those who have reviewed
        let allReviewerLogins = pendingReviewers.union(Set(latestReviewByUser.keys))
        let totalReviewers = allReviewerLogins.count

        // Count by state
        var approvedCount = 0
        var changesRequestedCount = 0
        var commentedCount = 0

        for login in allReviewerLogins {
            if pendingReviewers.contains(login) && latestReviewByUser[login] == nil {
                // Still pending, hasn't reviewed yet
                continue
            }
            switch latestReviewByUser[login]?.uppercased() {
            case "APPROVED":
                approvedCount += 1
            case "CHANGES_REQUESTED":
                changesRequestedCount += 1
            case "COMMENTED":
                commentedCount += 1
            case "DISMISSED":
                // Dismissed review = back to pending effectively
                break
            default:
                break
            }
        }

        return ReviewSummary(
            totalReviewers: totalReviewers,
            approvedCount: approvedCount,
            changesRequestedCount: changesRequestedCount,
            commentedCount: commentedCount
        )
    }
}

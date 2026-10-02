import Foundation

// MARK: - Default Filters

/// Provides the default set of filtering rules that ship with the app.
/// Each rule maps to a row in the event notification matrix.
/// Rules with `isEnabled = true` allow notifications through;
/// rules with `isEnabled = false` suppress them by default.
///
/// The FilterEngine is configured so that matching a rule means the event
/// is ALLOWED (delivered). Events that don't match any enabled rule are suppressed.
/// This is an allowlist model — you opt in to what you want to see.
struct DefaultFilters {

    static func create() -> [FilteringRule] {
        var rules: [FilteringRule] = []
        var priority = 0

        func nextPriority() -> Int {
            priority += 1
            return priority
        }

        // ===========================================
        // AUTHORED PR FILTERS
        // ===========================================

        rules.append(FilteringRule(
            id: UUID(),
            name: "Comments on my PRs",
            description: "Notify when someone else comments on a PR you authored",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.commentAdded), .prRole(.authored)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "Reviews on my PRs",
            description: "Notify when someone submits a review (approve, changes requested, or comment)",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.reviewSubmitted), .prRole(.authored)], mode: .allOf)
        ))

        // SonarCloud must be evaluated BEFORE generic CI rules (higher priority = lower number)
        rules.append(FilteringRule(
            id: UUID(),
            name: "SonarCloud results",
            description: "Notify on SonarCloud Code Analysis results (noisy — off by default)",
            priority: nextPriority(),
            isEnabled: false,
            predicate: .compound([
                .eventType(.checkCompleted),
                .prRole(.authored),
                .ciCheck(checkName: "SonarCloud", conclusion: nil)
            ], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "SDK Build success",
            description: "Notify when 'Build SDK / aws-sdk-pr-build' succeeds on your PR",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([
                .eventType(.checkCompleted),
                .prRole(.authored),
                .ciCheck(checkName: "aws-sdk-pr-build", conclusion: "success")
            ], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "CI failures (non-SonarCloud)",
            description: "Notify when any CI check fails on your PR (except SonarCloud)",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([
                .eventType(.checkCompleted),
                .prRole(.authored),
                .ciCheck(checkName: "", conclusion: "failure")
            ], mode: .allOf)
        ))

        // "Other CI successes" catches any remaining checkCompleted+success that wasn't SDK Build
        rules.append(FilteringRule(
            id: UUID(),
            name: "Other CI successes",
            description: "Notify when non-SDK CI checks succeed (noisy — off by default)",
            priority: nextPriority(),
            isEnabled: false,
            predicate: .compound([
                .eventType(.checkCompleted),
                .prRole(.authored),
                .ciCheck(checkName: "", conclusion: "success")
            ], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "Merge queue entered",
            description: "Notify when your PR enters the merge queue",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.enteredMergeQueue), .prRole(.authored)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "Merge queue failed",
            description: "Notify when your PR is removed from the merge queue (merge failed)",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.mergeQueueFailed), .prRole(.authored)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "PR merged",
            description: "Notify when your PR is merged",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.prMerged), .prRole(.authored)], mode: .allOf)
        ))

        // ===========================================
        // REVIEWING PR FILTERS
        // ===========================================

        rules.append(FilteringRule(
            id: UUID(),
            name: "Assigned as reviewer",
            description: "Notify when you are assigned to review a PR",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.reviewRequested), .prRole(.reviewing)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "Author pushed commits",
            description: "Notify when the author pushes new commits (re-review needed)",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.newCommitPushed), .prRole(.reviewing)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "Author commented",
            description: "Notify when the PR author responds to comments",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.commentAdded), .prRole(.reviewing)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "PR ready for review",
            description: "Notify when a draft PR becomes ready for review",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([.eventType(.prStateChanged), .prRole(.reviewing)], mode: .allOf)
        ))

        rules.append(FilteringRule(
            id: UUID(),
            name: "Reviewing PR closed/merged",
            description: "Notify when a PR you're reviewing is closed or merged",
            priority: nextPriority(),
            isEnabled: true,
            predicate: .compound([
                .prRole(.reviewing),
                .compound([.eventType(.prMerged), .eventType(.prStateChanged)], mode: .anyOf)
            ], mode: .allOf)
        ))

        return rules
    }
}

import Foundation

// MARK: - CI Notification Decision

struct CINotificationDecision: Sendable {
    let shouldNotify: Bool
    let reason: String
}

// MARK: - CI Evaluator

struct CIEvaluator {
    static let sonarCloudCheckName = "SonarCloud Code Analysis"
    static let sdkBuildCheckName = "Build SDK / aws-sdk-pr-build (pull_request)"

    /// Evaluates whether a check run completion should produce a notification.
    ///
    /// Decision matrix:
    /// | Check Name   | Role      | Conclusion | Notify? |
    /// |--------------|-----------|------------|---------|
    /// | SonarCloud*  | any       | any        | No      |
    /// | SDK Build    | authored  | success    | Yes     |
    /// | SDK Build    | authored  | failure    | Yes     |
    /// | Any other    | authored  | failure    | Yes     |
    /// | Any other    | authored  | success    | No      |
    /// | Any          | reviewing | any        | No      |
    static func evaluate(checkRun: CheckRunDTO, prRole: PRRole) -> CINotificationDecision {
        // Only consider completed check runs
        guard checkRun.status == "completed" else {
            return CINotificationDecision(
                shouldNotify: false,
                reason: "Check run is not yet completed (status: \(checkRun.status))"
            )
        }

        // SonarCloud checks are always suppressed (Req 6.1)
        if checkRun.name == sonarCloudCheckName {
            return CINotificationDecision(
                shouldNotify: false,
                reason: "SonarCloud checks are always suppressed"
            )
        }

        // CI notifications are suppressed for reviewing PRs (Req 6.5)
        if prRole == .reviewing {
            return CINotificationDecision(
                shouldNotify: false,
                reason: "CI notifications are suppressed for reviewing PRs"
            )
        }

        // At this point, role is .authored
        let conclusion = checkRun.conclusion ?? "unknown"

        // SDK Build check: notify for both success and failure (Req 6.3)
        if checkRun.name == sdkBuildCheckName {
            return CINotificationDecision(
                shouldNotify: true,
                reason: "SDK Build \(conclusion) on authored PR"
            )
        }

        // Any other check on authored PR: notify only for failure (Req 6.2, 6.4)
        if conclusion == "failure" {
            return CINotificationDecision(
                shouldNotify: true,
                reason: "Non-SDK check failure on authored PR"
            )
        }

        return CINotificationDecision(
            shouldNotify: false,
            reason: "Non-SDK check \(conclusion) on authored PR (only failures notify)"
        )
    }
}

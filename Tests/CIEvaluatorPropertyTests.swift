import Foundation
import Testing
@testable import ghBonk

// MARK: - Property 7: SonarCloud Exclusion
// **Validates: Requirements 6.1**
// For any conclusion and role, SonarCloud never notifies.

// MARK: - Property 8: CI Notification Matrix for Authored PRs
// **Validates: Requirements 6.2, 6.3, 6.4**
// Failure always notifies (non-SonarCloud); SDK Build success notifies; other success doesn't.

// MARK: - Property 9: No CI Notifications for Reviewing PRs
// **Validates: Requirements 6.5**
// Any check with role reviewing returns shouldNotify=false.

@Suite("CIEvaluator Property Tests")
struct CIEvaluatorPropertyTests {

    // MARK: - Helpers

    private func makeCheckRun(
        name: String = "Some Check",
        status: String = "completed",
        conclusion: String? = "success"
    ) -> CheckRunDTO {
        CheckRunDTO(
            id: 1,
            name: name,
            status: status,
            conclusion: conclusion,
            htmlURL: URL(string: "https://github.com/checks/1")!
        )
    }

    // MARK: - Conclusion and check name inputs

    /// All GitHub check run conclusion values
    static let allConclusions = [
        "success", "failure", "neutral", "cancelled",
        "skipped", "timed_out", "action_required"
    ]

    /// Representative non-SonarCloud, non-SDK-Build check names
    static let otherCheckNames = [
        "Unit Tests",
        "Lint",
        "Integration Tests",
        "Code Coverage",
        "Security Scan",
        "Type Check",
        "E2E Tests"
    ]

    // MARK: - Property 7: SonarCloud Exclusion

    @Test("Property 7: SonarCloud never notifies for any conclusion × any role",
          arguments: allConclusions, [PRRole.authored, PRRole.reviewing])
    func sonarCloudNeverNotifies(conclusion: String, role: PRRole) {
        let check = makeCheckRun(
            name: CIEvaluator.sonarCloudCheckName,
            conclusion: conclusion
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: role)
        #expect(
            decision.shouldNotify == false,
            "SonarCloud should never notify, but got shouldNotify=true for conclusion=\(conclusion), role=\(role)"
        )
    }

    // MARK: - Property 8: CI Notification Matrix for Authored PRs

    @Test("Property 8a: Any non-SonarCloud failure on authored PR always notifies",
          arguments: otherCheckNames + [CIEvaluator.sdkBuildCheckName])
    func failureAlwaysNotifiesAuthored(checkName: String) {
        let check = makeCheckRun(name: checkName, conclusion: "failure")
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(
            decision.shouldNotify == true,
            "Non-SonarCloud failure on authored PR should notify, but got shouldNotify=false for check=\(checkName)"
        )
    }

    @Test("Property 8b: SDK Build success on authored PR notifies")
    func sdkBuildSuccessNotifiesAuthored() {
        let check = makeCheckRun(
            name: CIEvaluator.sdkBuildCheckName,
            conclusion: "success"
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(
            decision.shouldNotify == true,
            "SDK Build success on authored PR should notify"
        )
    }

    @Test("Property 8c: Non-SDK-Build success on authored PR never notifies",
          arguments: otherCheckNames)
    func otherSuccessNeverNotifiesAuthored(checkName: String) {
        let check = makeCheckRun(name: checkName, conclusion: "success")
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(
            decision.shouldNotify == false,
            "Non-SDK check success on authored PR should not notify, but got shouldNotify=true for check=\(checkName)"
        )
    }

    @Test("Property 8d: Non-SDK-Build non-failure conclusions on authored PR are suppressed",
          arguments: otherCheckNames, ["success", "neutral", "cancelled", "skipped", "timed_out", "action_required"])
    func otherNonFailureConclusions(checkName: String, conclusion: String) {
        let check = makeCheckRun(name: checkName, conclusion: conclusion)
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(
            decision.shouldNotify == false,
            "Non-SDK check with conclusion=\(conclusion) on authored PR should not notify, but got shouldNotify=true for check=\(checkName)"
        )
    }

    @Test("Property 8e: SDK Build notifies for all conclusions on authored PR",
          arguments: allConclusions)
    func sdkBuildAlwaysNotifiesAuthored(conclusion: String) {
        let check = makeCheckRun(
            name: CIEvaluator.sdkBuildCheckName,
            conclusion: conclusion
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(
            decision.shouldNotify == true,
            "SDK Build on authored PR should always notify, but got shouldNotify=false for conclusion=\(conclusion)"
        )
    }

    // MARK: - Property 9: No CI Notifications for Reviewing PRs

    @Test("Property 9: Any check with role=reviewing never notifies",
          arguments: [CIEvaluator.sonarCloudCheckName, CIEvaluator.sdkBuildCheckName] + otherCheckNames,
          allConclusions)
    func reviewingNeverNotifies(checkName: String, conclusion: String) {
        let check = makeCheckRun(name: checkName, conclusion: conclusion)
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .reviewing)
        #expect(
            decision.shouldNotify == false,
            "Reviewing PRs should never notify, but got shouldNotify=true for check=\(checkName), conclusion=\(conclusion)"
        )
    }
}

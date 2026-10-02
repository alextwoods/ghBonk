import Testing
import Foundation
@testable import ghBonk

@Suite("CIEvaluator Tests")
struct CIEvaluatorTests {

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

    // MARK: - Non-completed checks

    @Test("In-progress check run returns shouldNotify=false")
    func inProgressCheck() {
        let check = makeCheckRun(status: "in_progress", conclusion: nil)
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == false)
        #expect(decision.reason.contains("not yet completed"))
    }

    @Test("Queued check run returns shouldNotify=false")
    func queuedCheck() {
        let check = makeCheckRun(status: "queued", conclusion: nil)
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == false)
        #expect(decision.reason.contains("not yet completed"))
    }

    // MARK: - SonarCloud (Req 6.1)

    @Test("SonarCloud check is always suppressed regardless of role or conclusion",
          arguments: [PRRole.authored, PRRole.reviewing],
          ["success", "failure", "neutral"])
    func sonarCloudAlwaysSuppressed(role: PRRole, conclusion: String) {
        let check = makeCheckRun(
            name: CIEvaluator.sonarCloudCheckName,
            conclusion: conclusion
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: role)
        #expect(decision.shouldNotify == false)
        #expect(decision.reason.contains("SonarCloud"))
    }

    // MARK: - Reviewing PRs (Req 6.5)

    @Test("Any check on a reviewing PR returns shouldNotify=false",
          arguments: ["success", "failure", "neutral"])
    func reviewingPRAlwaysSuppressed(conclusion: String) {
        let check = makeCheckRun(name: "Arbitrary CI Check", conclusion: conclusion)
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .reviewing)
        #expect(decision.shouldNotify == false)
        #expect(decision.reason.contains("reviewing"))
    }

    @Test("SDK Build on reviewing PR is suppressed")
    func sdkBuildOnReviewingPR() {
        let check = makeCheckRun(
            name: CIEvaluator.sdkBuildCheckName,
            conclusion: "success"
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .reviewing)
        #expect(decision.shouldNotify == false)
    }

    // MARK: - SDK Build on authored PR (Req 6.3)

    @Test("SDK Build success on authored PR notifies")
    func sdkBuildSuccessAuthored() {
        let check = makeCheckRun(
            name: CIEvaluator.sdkBuildCheckName,
            conclusion: "success"
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == true)
        #expect(decision.reason.contains("SDK Build"))
        #expect(decision.reason.contains("success"))
    }

    @Test("SDK Build failure on authored PR notifies")
    func sdkBuildFailureAuthored() {
        let check = makeCheckRun(
            name: CIEvaluator.sdkBuildCheckName,
            conclusion: "failure"
        )
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == true)
        #expect(decision.reason.contains("SDK Build"))
        #expect(decision.reason.contains("failure"))
    }

    // MARK: - Other checks on authored PR (Req 6.2, 6.4)

    @Test("Non-SDK check failure on authored PR notifies")
    func otherCheckFailureAuthored() {
        let check = makeCheckRun(name: "Unit Tests", conclusion: "failure")
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == true)
        #expect(decision.reason.contains("Non-SDK check failure"))
    }

    @Test("Non-SDK check success on authored PR is suppressed")
    func otherCheckSuccessAuthored() {
        let check = makeCheckRun(name: "Unit Tests", conclusion: "success")
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == false)
        #expect(decision.reason.contains("only failures notify"))
    }

    @Test("Non-SDK check neutral conclusion on authored PR is suppressed")
    func otherCheckNeutralAuthored() {
        let check = makeCheckRun(name: "Lint", conclusion: "neutral")
        let decision = CIEvaluator.evaluate(checkRun: check, prRole: .authored)
        #expect(decision.shouldNotify == false)
    }
}

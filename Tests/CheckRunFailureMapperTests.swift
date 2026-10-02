import Testing
import Foundation
@testable import ghBonk

@Suite("CheckRunFailureMapper Tests")
struct CheckRunFailureMapperTests {

    // MARK: - Helpers

    private func makeCheckRun(
        id: Int = 42,
        name: String = "Unit Tests",
        status: String = "completed",
        conclusion: String? = "failure",
        htmlURL: URL = URL(string: "https://github.com/owner/repo/runs/42")!
    ) -> CheckRunDTO {
        CheckRunDTO(
            id: id,
            name: name,
            status: status,
            conclusion: conclusion,
            htmlURL: htmlURL
        )
    }

    // MARK: - map(checkRun:) - successful mapping

    @Test("Completed failure check run produces a CheckRunFailure")
    func completedFailureProducesResult() {
        let checkRun = makeCheckRun()
        let result = CheckRunFailureMapper.map(checkRun: checkRun)

        #expect(result != nil)
        #expect(result?.checkName == "Unit Tests")
        #expect(result?.failureURL == URL(string: "https://github.com/owner/repo/runs/42")!)
        #expect(result?.runID == 42)
        #expect(result?.conclusion == "failure")
    }

    @Test("Raw payload contains valid JSON with check run data")
    func rawPayloadIsValidJSON() throws {
        let checkRun = makeCheckRun(id: 99, name: "Build SDK", conclusion: "failure")
        let result = CheckRunFailureMapper.map(checkRun: checkRun)

        let payload = try #require(result?.rawPayload)
        #expect(!payload.isEmpty)

        // Verify it's valid JSON that can be decoded back
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CheckRunDTO.self, from: payload)
        #expect(decoded.id == 99)
        #expect(decoded.name == "Build SDK")
        #expect(decoded.conclusion == "failure")
        #expect(decoded.status == "completed")
    }

    // MARK: - map(checkRun:) - returns nil for non-failures

    @Test("Non-completed check run returns nil",
          arguments: ["in_progress", "queued"])
    func nonCompletedReturnsNil(status: String) {
        let checkRun = makeCheckRun(status: status, conclusion: nil)
        let result = CheckRunFailureMapper.map(checkRun: checkRun)
        #expect(result == nil)
    }

    @Test("Completed check with non-failure conclusion returns nil",
          arguments: ["success", "neutral", "cancelled", "skipped", "timed_out", "action_required"])
    func nonFailureConclusionReturnsNil(conclusion: String) {
        let checkRun = makeCheckRun(conclusion: conclusion)
        let result = CheckRunFailureMapper.map(checkRun: checkRun)
        #expect(result == nil)
    }

    @Test("Completed check with nil conclusion returns nil")
    func nilConclusionReturnsNil() {
        let checkRun = makeCheckRun(conclusion: nil)
        let result = CheckRunFailureMapper.map(checkRun: checkRun)
        #expect(result == nil)
    }

    // MARK: - mapFailures(from:) - batch processing

    @Test("mapFailures returns only failures from a mixed array")
    func mapFailuresFiltersMixed() {
        let checkRuns = [
            makeCheckRun(id: 1, name: "Lint", status: "completed", conclusion: "success"),
            makeCheckRun(id: 2, name: "Build", status: "completed", conclusion: "failure"),
            makeCheckRun(id: 3, name: "Tests", status: "in_progress", conclusion: nil),
            makeCheckRun(id: 4, name: "Deploy", status: "completed", conclusion: "failure"),
            makeCheckRun(id: 5, name: "Coverage", status: "completed", conclusion: "neutral"),
        ]

        let failures = CheckRunFailureMapper.mapFailures(from: checkRuns)

        #expect(failures.count == 2)
        #expect(failures[0].runID == 2)
        #expect(failures[0].checkName == "Build")
        #expect(failures[1].runID == 4)
        #expect(failures[1].checkName == "Deploy")
    }

    @Test("mapFailures returns empty array when no failures exist")
    func mapFailuresEmptyWhenNoFailures() {
        let checkRuns = [
            makeCheckRun(id: 1, status: "completed", conclusion: "success"),
            makeCheckRun(id: 2, status: "completed", conclusion: "neutral"),
        ]

        let failures = CheckRunFailureMapper.mapFailures(from: checkRuns)
        #expect(failures.isEmpty)
    }

    @Test("mapFailures returns empty array for empty input")
    func mapFailuresEmptyInput() {
        let failures = CheckRunFailureMapper.mapFailures(from: [])
        #expect(failures.isEmpty)
    }

    // MARK: - Mapping correctness

    @Test("CheckRunFailure fields correctly map from CheckRunDTO")
    func fieldMappingCorrectness() {
        let url = URL(string: "https://github.com/aws/aws-sdk-java-v2/actions/runs/12345")!
        let checkRun = makeCheckRun(id: 12345, name: "Build SDK / aws-sdk-pr-build (pull_request)", conclusion: "failure", htmlURL: url)

        let result = CheckRunFailureMapper.map(checkRun: checkRun)

        #expect(result?.checkName == "Build SDK / aws-sdk-pr-build (pull_request)")
        #expect(result?.failureURL == url)
        #expect(result?.runID == 12345)
        #expect(result?.conclusion == "failure")
    }
}

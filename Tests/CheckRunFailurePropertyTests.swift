import Foundation
import Testing
@testable import ghBonk

// MARK: - Property 19: CheckRunFailure Model Completeness
// **Validates: Requirements 12.1**
// For any CheckRunDTO with failure conclusion, mapped CheckRunFailure has all required fields populated.

@Suite("CheckRunFailure Property Tests")
struct CheckRunFailurePropertyTests {

    // MARK: - Test Inputs

    /// Various check names including names with special characters and long paths
    static let checkNames = [
        "Build SDK / aws-sdk-pr-build (pull_request)",
        "Unit Tests",
        "Integration Tests",
        "Code Coverage",
        "Security Scan (linux/amd64)",
        "CI: build & test [nightly]",
        "check/name-with-dashes_and_underscores",
        "名前チェック (unicode)",
        "A",
    ]

    /// Various run IDs across the positive integer range
    static let runIDs = [1, 42, 100, 999_999, Int.max]

    /// Various valid HTML URLs
    static let htmlURLStrings = [
        "https://github.com/owner/repo/runs/1",
        "https://github.com/aws/aws-sdk-java-v2/actions/runs/999999",
        "https://github.com/org/repo-with-dashes/actions/runs/42",
    ]

    // MARK: - Helpers

    private func makeFailedCheckRun(
        id: Int,
        name: String,
        htmlURL: URL
    ) -> CheckRunDTO {
        CheckRunDTO(
            id: id,
            name: name,
            status: "completed",
            conclusion: "failure",
            htmlURL: htmlURL
        )
    }

    // MARK: - Property 19: Model Completeness

    @Test("Property 19: All required fields populated for any check name with failure conclusion",
          arguments: checkNames)
    func allFieldsPopulatedForCheckName(checkName: String) throws {
        let url = URL(string: "https://github.com/owner/repo/runs/42")!
        let checkRun = makeFailedCheckRun(id: 42, name: checkName, htmlURL: url)

        let result = try #require(CheckRunFailureMapper.map(checkRun: checkRun))

        // checkName is non-empty
        #expect(!result.checkName.isEmpty, "checkName must be non-empty")
        // checkName matches input
        #expect(result.checkName == checkName)
        // failureURL is a valid URL (non-nil by construction, but verify scheme)
        #expect(result.failureURL.scheme == "https")
        // runID is > 0
        #expect(result.runID > 0, "runID must be > 0")
        // conclusion is non-empty
        #expect(!result.conclusion.isEmpty, "conclusion must be non-empty")
        #expect(result.conclusion == "failure")
        // rawPayload is non-empty
        #expect(!result.rawPayload.isEmpty, "rawPayload must be non-empty")
    }

    @Test("Property 19: All required fields populated for any run ID",
          arguments: runIDs)
    func allFieldsPopulatedForRunID(runID: Int) throws {
        let url = URL(string: "https://github.com/owner/repo/runs/\(runID)")!
        let checkRun = makeFailedCheckRun(id: runID, name: "Unit Tests", htmlURL: url)

        let result = try #require(CheckRunFailureMapper.map(checkRun: checkRun))

        #expect(!result.checkName.isEmpty, "checkName must be non-empty")
        #expect(result.failureURL == url)
        #expect(result.runID == runID)
        #expect(result.runID > 0, "runID must be > 0")
        #expect(!result.conclusion.isEmpty, "conclusion must be non-empty")
        #expect(!result.rawPayload.isEmpty, "rawPayload must be non-empty")
    }

    @Test("Property 19: All required fields populated for any URL",
          arguments: htmlURLStrings)
    func allFieldsPopulatedForURL(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        let checkRun = makeFailedCheckRun(id: 100, name: "Build", htmlURL: url)

        let result = try #require(CheckRunFailureMapper.map(checkRun: checkRun))

        #expect(!result.checkName.isEmpty, "checkName must be non-empty")
        #expect(result.failureURL == url)
        #expect(result.runID > 0, "runID must be > 0")
        #expect(!result.conclusion.isEmpty, "conclusion must be non-empty")
        #expect(!result.rawPayload.isEmpty, "rawPayload must be non-empty")
    }

    // MARK: - rawPayload round-trip verification

    @Test("Property 19: rawPayload decodes back to valid CheckRunDTO for any check name",
          arguments: checkNames)
    func rawPayloadRoundTrip(checkName: String) throws {
        let url = URL(string: "https://github.com/owner/repo/runs/77")!
        let checkRun = makeFailedCheckRun(id: 77, name: checkName, htmlURL: url)

        let result = try #require(CheckRunFailureMapper.map(checkRun: checkRun))

        // rawPayload must be valid JSON that decodes to a CheckRunDTO
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CheckRunDTO.self, from: result.rawPayload)

        #expect(decoded.id == checkRun.id)
        #expect(decoded.name == checkRun.name)
        #expect(decoded.status == checkRun.status)
        #expect(decoded.conclusion == checkRun.conclusion)
        #expect(decoded.htmlURL == checkRun.htmlURL)
    }

    @Test("Property 19: rawPayload decodes back to valid CheckRunDTO for any run ID",
          arguments: runIDs)
    func rawPayloadRoundTripByID(runID: Int) throws {
        let url = URL(string: "https://github.com/owner/repo/runs/\(runID)")!
        let checkRun = makeFailedCheckRun(id: runID, name: "Integration Tests", htmlURL: url)

        let result = try #require(CheckRunFailureMapper.map(checkRun: checkRun))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CheckRunDTO.self, from: result.rawPayload)

        #expect(decoded.id == runID)
        #expect(decoded.name == "Integration Tests")
        #expect(decoded.status == "completed")
        #expect(decoded.conclusion == "failure")
    }

    // MARK: - Combined parameterization (check name × run ID)

    @Test("Property 19: Model completeness across check name × run ID combinations",
          arguments: checkNames, runIDs)
    func modelCompletenessFullCross(checkName: String, runID: Int) throws {
        let url = URL(string: "https://github.com/owner/repo/runs/\(runID)")!
        let checkRun = makeFailedCheckRun(id: runID, name: checkName, htmlURL: url)

        let result = try #require(
            CheckRunFailureMapper.map(checkRun: checkRun),
            "Mapper returned nil for completed failure check run"
        )

        // All required fields must be populated
        #expect(!result.checkName.isEmpty)
        #expect(result.failureURL.absoluteString.contains("http"))
        #expect(result.runID > 0)
        #expect(!result.conclusion.isEmpty)
        #expect(!result.rawPayload.isEmpty)

        // rawPayload must be valid JSON
        let json = try JSONSerialization.jsonObject(with: result.rawPayload)
        #expect(json is [String: Any], "rawPayload must decode as a JSON object")
    }
}

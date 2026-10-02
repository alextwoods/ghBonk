import Foundation

// MARK: - CheckRunFailureMapper

/// Maps `CheckRunDTO` instances with a failure conclusion to `CheckRunFailure` structs
/// suitable for persistence and future analysis.
///
/// Requirements:
/// - 12.1: Models Check_Run failures as structured data (check name, failure URL, run ID, conclusion).
/// - 12.3: Persists raw Check_Run failure payloads for future offline analysis.
struct CheckRunFailureMapper {

    /// Maps a completed, failed `CheckRunDTO` to a `CheckRunFailure`.
    ///
    /// Returns `nil` if the check run has not completed or did not fail.
    ///
    /// - Parameter checkRun: The check run DTO from the GitHub API.
    /// - Returns: A `CheckRunFailure` if the check run completed with a failure conclusion; otherwise `nil`.
    static func map(checkRun: CheckRunDTO) -> CheckRunFailure? {
        guard checkRun.status == "completed",
              checkRun.conclusion == "failure" else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let rawPayload = (try? encoder.encode(checkRun)) ?? Data()

        return CheckRunFailure(
            checkName: checkRun.name,
            failureURL: checkRun.htmlURL,
            runID: checkRun.id,
            conclusion: checkRun.conclusion ?? "failure",
            rawPayload: rawPayload
        )
    }

    /// Maps an array of `CheckRunDTO` to only the failures.
    ///
    /// Convenience method for batch processing check runs from a single poll cycle.
    ///
    /// - Parameter checkRuns: All check runs for a given PR.
    /// - Returns: An array of `CheckRunFailure` for each check that completed with failure.
    static func mapFailures(from checkRuns: [CheckRunDTO]) -> [CheckRunFailure] {
        checkRuns.compactMap { map(checkRun: $0) }
    }
}

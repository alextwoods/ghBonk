import Foundation

// MARK: - Build Failure Analysis Extension Point

/// Extension point for future build failure investigation modules.
/// Conforming types can analyze CheckRun failures without modifying
/// core polling or notification logic (Requirement 12.2).
protocol BuildFailureAnalyzer: Sendable {
    /// Analyzes a check run failure and returns investigation results.
    func analyze(failure: CheckRunFailure) async throws -> AnalysisResult
}

struct CheckRunFailure: Codable, Equatable, Sendable {
    let checkName: String
    let failureURL: URL
    let runID: Int
    let conclusion: String
    let rawPayload: Data  // Persisted for offline analysis (Req 12.3)
}

struct AnalysisResult: Sendable {
    let summary: String
    let suggestedActions: [String]
    let confidence: Double
}

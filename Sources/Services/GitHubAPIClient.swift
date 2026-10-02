import Foundation

// MARK: - GitHubAPIClientProtocol

protocol GitHubAPIClientProtocol: Sendable {
    func validateToken(_ token: String) async throws -> GitHubUser
    func fetchPullRequests(repo: Repository) async throws -> [PullRequestDTO]
    func fetchCheckRuns(repo: Repository, ref: String) async throws -> [CheckRunDTO]
    func fetchReviewRequests(repo: Repository, prNumber: Int) async throws -> ReviewRequestsDTO
    func fetchIssueComments(repo: Repository, prNumber: Int) async throws -> [IssueCommentDTO]
    func fetchReviewComments(repo: Repository, prNumber: Int) async throws -> [ReviewCommentDTO]
    func fetchReviews(repo: Repository, prNumber: Int) async throws -> [ReviewDTO]
    func fetchCommits(repo: Repository, prNumber: Int) async throws -> [CommitDTO]
}

// MARK: - GitHubAPIClient

actor GitHubAPIClient: GitHubAPIClientProtocol {
    private let session: URLSession
    private let baseURL: URL = URL(string: "https://api.github.com")!
    private var token: String
    private var rateLimitResetDate: Date?
    private let retryPolicy: RetryPolicy

    init(token: String, session: URLSession = .shared, retryPolicy: RetryPolicy = RetryPolicy()) {
        self.token = token
        self.session = session
        self.retryPolicy = retryPolicy
    }

    func updateToken(_ token: String) {
        self.token = token
    }

    // MARK: - Protocol Methods

    func validateToken(_ token: String) async throws -> GitHubUser {
        let url = baseURL.appendingPathComponent("user")
        var request = makeRequest(url: url)
        // Use the provided token for validation (may differ from stored token)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await performRequest(request)
        return try decoder.decode(GitHubUser.self, from: data)
    }

    func fetchPullRequests(repo: Repository) async throws -> [PullRequestDTO] {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("pulls")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: "100")
        ]
        let request = makeRequest(url: components.url!)
        let data = try await performRequest(request)
        return try decoder.decode([PullRequestDTO].self, from: data)
    }

    func fetchCheckRuns(repo: Repository, ref: String) async throws -> [CheckRunDTO] {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("commits")
            .appendingPathComponent(ref)
            .appendingPathComponent("check-runs")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100")
        ]
        let request = makeRequest(url: components.url!)
        let data = try await performRequest(request)
        let response = try decoder.decode(CheckRunsResponse.self, from: data)
        return response.checkRuns
    }

    func fetchReviewRequests(repo: Repository, prNumber: Int) async throws -> ReviewRequestsDTO {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent("\(prNumber)")
            .appendingPathComponent("requested_reviewers")
        let request = makeRequest(url: url)
        let data = try await performRequest(request)
        return try decoder.decode(ReviewRequestsDTO.self, from: data)
    }

    func fetchIssueComments(repo: Repository, prNumber: Int) async throws -> [IssueCommentDTO] {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("issues")
            .appendingPathComponent("\(prNumber)")
            .appendingPathComponent("comments")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc")
        ]
        let request = makeRequest(url: components.url!)
        let data = try await performRequest(request)
        return try decoder.decode([IssueCommentDTO].self, from: data)
    }

    func fetchReviewComments(repo: Repository, prNumber: Int) async throws -> [ReviewCommentDTO] {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent("\(prNumber)")
            .appendingPathComponent("comments")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc")
        ]
        let request = makeRequest(url: components.url!)
        let data = try await performRequest(request)
        return try decoder.decode([ReviewCommentDTO].self, from: data)
    }

    func fetchReviews(repo: Repository, prNumber: Int) async throws -> [ReviewDTO] {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent("\(prNumber)")
            .appendingPathComponent("reviews")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100")
        ]
        let request = makeRequest(url: components.url!)
        let data = try await performRequest(request)
        return try decoder.decode([ReviewDTO].self, from: data)
    }

    func fetchCommits(repo: Repository, prNumber: Int) async throws -> [CommitDTO] {
        let url = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent("\(prNumber)")
            .appendingPathComponent("commits")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100")
        ]
        let request = makeRequest(url: components.url!)
        let data = try await performRequest(request)
        return try decoder.decode([CommitDTO].self, from: data)
    }

    // MARK: - Private Helpers

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Performs a request with retry logic for network errors and rate-limit short-circuiting.
    private func performRequest(_ request: URLRequest) async throws -> Data {
        // Short-circuit if we are currently rate-limited
        if let resetDate = rateLimitResetDate, Date() < resetDate {
            throw GhBonkError.rateLimited(resetDate: resetDate)
        }

        var lastError: Error?

        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GhBonkError.networkUnavailable
                }

                switch httpResponse.statusCode {
                case 200..<300:
                    return data

                case 401:
                    throw GhBonkError.tokenInvalid

                case 403:
                    if isRateLimited(response: httpResponse) {
                        let resetDate = parseRateLimitReset(response: httpResponse)
                        self.rateLimitResetDate = resetDate
                        throw GhBonkError.rateLimited(resetDate: resetDate)
                    }
                    let body = String(data: data, encoding: .utf8)
                    throw GhBonkError.httpError(statusCode: 403, body: body)

                case 404:
                    let fullName = extractRepoFullName(from: request.url)
                    throw GhBonkError.repositoryNotFound(fullName: fullName)

                default:
                    let body = String(data: data, encoding: .utf8)
                    throw GhBonkError.httpError(statusCode: httpResponse.statusCode, body: body)
                }
            } catch let error as URLError {
                // Network errors are retryable
                lastError = error
                if attempt < retryPolicy.maxAttempts - 1 {
                    let delay = retryPolicy.delay(for: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch let error as GhBonkError {
                // GhBonkErrors (HTTP mapped errors, rate limits) are not retried
                throw error
            } catch {
                // Other unexpected errors are not retried
                throw error
            }
        }

        throw GhBonkError.maxRetriesExceeded(underlyingError: lastError ?? URLError(.unknown))
    }

    private func isRateLimited(response: HTTPURLResponse) -> Bool {
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           remaining == "0" {
            return true
        }
        return false
    }

    private func parseRateLimitReset(response: HTTPURLResponse) -> Date {
        if let resetString = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let resetTimestamp = TimeInterval(resetString) {
            return Date(timeIntervalSince1970: resetTimestamp)
        }
        // Fallback: reset in 60 seconds if header is missing or unparseable
        return Date().addingTimeInterval(60)
    }

    private func extractRepoFullName(from url: URL?) -> String {
        guard let url = url else { return "unknown" }
        let components = url.pathComponents
        // GitHub API URLs follow pattern: /repos/{owner}/{repo}/...
        if let reposIndex = components.firstIndex(of: "repos"),
           components.count > reposIndex + 2 {
            return "\(components[reposIndex + 1])/\(components[reposIndex + 2])"
        }
        return "unknown"
    }
}

// MARK: - Internal Response Types

/// Wrapper for the GitHub check-runs API response which nests runs in a `check_runs` array.
private struct CheckRunsResponse: Codable {
    let totalCount: Int
    let checkRuns: [CheckRunDTO]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case checkRuns = "check_runs"
    }
}

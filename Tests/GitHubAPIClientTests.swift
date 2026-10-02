import Foundation
import Testing
@testable import ghBonk

// MARK: - Mock URLProtocol

/// A `URLProtocol` subclass that returns pre-configured responses for testing.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Handler that returns (response, data) or throws an error for a given request.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test Helpers

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeHTTPResponse(url: URL, statusCode: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private let testRepo = Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0)

// MARK: - Tests

@Suite("GitHubAPIClient Tests", .serialized)
struct GitHubAPIClientTests {

    // MARK: - Request Headers

    @Test("Requests include correct Authorization, Accept, and API version headers")
    func requestHeaders() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test123", session: session)

        MockURLProtocol.requestHandler = { request in
            // Verify headers
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test123")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")

            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            {"users": [], "teams": []}
            """.data(using: .utf8)!
            return (response, data)
        }

        _ = try await client.fetchReviewRequests(repo: testRepo, prNumber: 1)
    }

    // MARK: - validateToken

    @Test("validateToken returns GitHubUser on success")
    func validateTokenSuccess() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_stored", session: session)

        MockURLProtocol.requestHandler = { request in
            // Validate that the provided token is used (not the stored one)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_validate_me")
            #expect(request.url?.path == "/user")

            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            {"login": "octocat", "id": 42}
            """.data(using: .utf8)!
            return (response, data)
        }

        let user = try await client.validateToken("ghp_validate_me")
        #expect(user.login == "octocat")
        #expect(user.id == 42)
    }

    // MARK: - fetchPullRequests

    @Test("fetchPullRequests decodes array of PullRequestDTO")
    func fetchPullRequestsSuccess() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/repos/aws/aws-sdk-java-v2/pulls")
            let urlComponents = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let queryItems = urlComponents?.queryItems ?? []
            #expect(queryItems.contains(URLQueryItem(name: "state", value: "open")))
            #expect(queryItems.contains(URLQueryItem(name: "per_page", value: "100")))

            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            [
              {
                "number": 5123,
                "title": "Add feature X",
                "state": "open",
                "draft": false,
                "user": {"login": "dev1", "id": 100},
                "head": {"ref": "feature-x", "sha": "abc123def"},
                "updated_at": "2024-01-15T10:30:00Z",
                "html_url": "https://github.com/aws/aws-sdk-java-v2/pull/5123"
              }
            ]
            """.data(using: .utf8)!
            return (response, data)
        }

        let prs = try await client.fetchPullRequests(repo: testRepo)
        #expect(prs.count == 1)
        #expect(prs[0].number == 5123)
        #expect(prs[0].title == "Add feature X")
        #expect(prs[0].headRef == "feature-x")
        #expect(prs[0].head.sha == "abc123def")
        #expect(prs[0].draft == false)
        #expect(prs[0].user.login == "dev1")
    }

    // MARK: - fetchCheckRuns

    @Test("fetchCheckRuns decodes nested check_runs array")
    func fetchCheckRunsSuccess() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/repos/aws/aws-sdk-java-v2/commits/abc123/check-runs")

            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            {
              "total_count": 1,
              "check_runs": [
                {
                  "id": 9001,
                  "name": "Build SDK / aws-sdk-pr-build (pull_request)",
                  "status": "completed",
                  "conclusion": "success",
                  "html_url": "https://github.com/aws/aws-sdk-java-v2/runs/9001"
                }
              ]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let checks = try await client.fetchCheckRuns(repo: testRepo, ref: "abc123")
        #expect(checks.count == 1)
        #expect(checks[0].name == "Build SDK / aws-sdk-pr-build (pull_request)")
        #expect(checks[0].conclusion == "success")
        #expect(checks[0].status == "completed")
    }

    // MARK: - fetchReviewRequests

    @Test("fetchReviewRequests decodes users and teams")
    func fetchReviewRequestsSuccess() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/repos/aws/aws-sdk-java-v2/pulls/42/requested_reviewers")

            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            {
              "users": [{"login": "reviewer1", "id": 200}],
              "teams": [{"slug": "core-team", "name": "Core Team"}]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let reviewRequests = try await client.fetchReviewRequests(repo: testRepo, prNumber: 42)
        #expect(reviewRequests.users.count == 1)
        #expect(reviewRequests.users[0].login == "reviewer1")
        #expect(reviewRequests.teams.count == 1)
        #expect(reviewRequests.teams[0].slug == "core-team")
    }

    // MARK: - HTTP Error Mapping

    @Test("401 response throws tokenInvalid")
    func httpError401() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_bad", session: session)

        MockURLProtocol.requestHandler = { request in
            let response = makeHTTPResponse(url: request.url!, statusCode: 401)
            let data = """
            {"message": "Bad credentials"}
            """.data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected tokenInvalid error")
        } catch let error as GhBonkError {
            guard case .tokenInvalid = error else {
                Issue.record("Expected tokenInvalid, got \(error)")
                return
            }
        }
    }

    @Test("404 response throws repositoryNotFound with full name")
    func httpError404() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)

        MockURLProtocol.requestHandler = { request in
            let response = makeHTTPResponse(url: request.url!, statusCode: 404)
            let data = """
            {"message": "Not Found"}
            """.data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected repositoryNotFound error")
        } catch let error as GhBonkError {
            guard case .repositoryNotFound(let fullName) = error else {
                Issue.record("Expected repositoryNotFound, got \(error)")
                return
            }
            #expect(fullName == "aws/aws-sdk-java-v2")
        }
    }

    @Test("500 response throws httpError with status code and body")
    func httpError500() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)

        MockURLProtocol.requestHandler = { request in
            let response = makeHTTPResponse(url: request.url!, statusCode: 500)
            let data = "Internal Server Error".data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected httpError")
        } catch let error as GhBonkError {
            guard case .httpError(let statusCode, let body) = error else {
                Issue.record("Expected httpError, got \(error)")
                return
            }
            #expect(statusCode == 500)
            #expect(body == "Internal Server Error")
        }
    }

    // MARK: - Rate Limiting

    @Test("403 with X-RateLimit-Remaining: 0 throws rateLimited and stores reset date")
    func rateLimitHandling() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)
        let futureTimestamp = String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))

        MockURLProtocol.requestHandler = { request in
            let headers = [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": futureTimestamp
            ]
            let response = makeHTTPResponse(url: request.url!, statusCode: 403, headers: headers)
            let data = """
            {"message": "API rate limit exceeded"}
            """.data(using: .utf8)!
            return (response, data)
        }

        // First call should throw rateLimited
        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected rateLimited error")
        } catch let error as GhBonkError {
            guard case .rateLimited(let resetDate) = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
            #expect(resetDate.timeIntervalSince1970 == Double(futureTimestamp)!)
        }

        // Subsequent calls should short-circuit without hitting the network
        var requestMade = false
        MockURLProtocol.requestHandler = { _ in
            requestMade = true
            let response = makeHTTPResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: 200
            )
            return (response, Data())
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected rateLimited error on subsequent call")
        } catch let error as GhBonkError {
            guard case .rateLimited = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
        }
        #expect(requestMade == false, "Should short-circuit without making a network request")
    }

    @Test("403 without rate limit headers throws httpError")
    func nonRateLimit403() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_test", session: session)

        MockURLProtocol.requestHandler = { request in
            // No X-RateLimit-Remaining header
            let response = makeHTTPResponse(url: request.url!, statusCode: 403)
            let data = """
            {"message": "Forbidden"}
            """.data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected httpError")
        } catch let error as GhBonkError {
            guard case .httpError(let statusCode, _) = error else {
                Issue.record("Expected httpError, got \(error)")
                return
            }
            #expect(statusCode == 403)
        }
    }

    // MARK: - Retry Logic

    @Test("Network errors trigger retries up to max attempts, then throw maxRetriesExceeded")
    func retryOnNetworkError() async throws {
        let session = makeSession()
        let retryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, multiplier: 2.0)
        let client = GitHubAPIClient(token: "ghp_test", session: session, retryPolicy: retryPolicy)

        var attemptCount = 0
        MockURLProtocol.requestHandler = { _ in
            attemptCount += 1
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected maxRetriesExceeded error")
        } catch let error as GhBonkError {
            guard case .maxRetriesExceeded = error else {
                Issue.record("Expected maxRetriesExceeded, got \(error)")
                return
            }
        }

        #expect(attemptCount == 3, "Should have attempted 3 times")
    }

    @Test("Network error succeeds on second attempt")
    func retrySucceedsOnSecondAttempt() async throws {
        let session = makeSession()
        let retryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, multiplier: 2.0)
        let client = GitHubAPIClient(token: "ghp_test", session: session, retryPolicy: retryPolicy)

        var attemptCount = 0
        MockURLProtocol.requestHandler = { request in
            attemptCount += 1
            if attemptCount == 1 {
                throw URLError(.timedOut)
            }
            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            {"users": [], "teams": []}
            """.data(using: .utf8)!
            return (response, data)
        }

        let result = try await client.fetchReviewRequests(repo: testRepo, prNumber: 1)
        #expect(attemptCount == 2)
        #expect(result.users.isEmpty)
    }

    @Test("HTTP errors are not retried")
    func noRetryOnHTTPError() async throws {
        let session = makeSession()
        let retryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, multiplier: 2.0)
        let client = GitHubAPIClient(token: "ghp_test", session: session, retryPolicy: retryPolicy)

        var attemptCount = 0
        MockURLProtocol.requestHandler = { request in
            attemptCount += 1
            let response = makeHTTPResponse(url: request.url!, statusCode: 401)
            let data = "{}".data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await client.fetchPullRequests(repo: testRepo)
            Issue.record("Expected tokenInvalid error")
        } catch {
            // Expected
        }

        #expect(attemptCount == 1, "HTTP errors should not be retried")
    }

    // MARK: - Token Update

    @Test("updateToken changes the token used for requests")
    func updateToken() async throws {
        let session = makeSession()
        let client = GitHubAPIClient(token: "ghp_old", session: session)

        await client.updateToken("ghp_new")

        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_new")
            let response = makeHTTPResponse(url: request.url!, statusCode: 200)
            let data = """
            {"users": [], "teams": []}
            """.data(using: .utf8)!
            return (response, data)
        }

        _ = try await client.fetchReviewRequests(repo: testRepo, prNumber: 1)
    }
}

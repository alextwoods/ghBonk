import Foundation

// MARK: - GitHub API Data Transfer Objects

struct GitHubUser: Codable, Equatable, Sendable {
    let login: String
    let id: Int
}

struct PullRequestDTO: Codable, Equatable, Sendable {
    let number: Int
    let title: String
    let state: String
    let draft: Bool
    let user: GitHubUser
    let head: HeadInfo
    let updatedAt: Date
    let htmlURL: URL
    let mergedAt: Date?
    let autoMerge: AutoMergeInfo?

    var headRef: String { head.ref }

    /// Whether this PR is currently in the merge queue.
    var isInMergeQueue: Bool {
        autoMerge != nil && state == "open" && mergedAt == nil
    }

    struct HeadInfo: Codable, Equatable, Sendable {
        let ref: String
        let sha: String
    }

    struct AutoMergeInfo: Codable, Equatable, Sendable {
        let enabledBy: GitHubUser?
        let mergeMethod: String?

        enum CodingKeys: String, CodingKey {
            case enabledBy = "enabled_by"
            case mergeMethod = "merge_method"
        }
    }

    enum CodingKeys: String, CodingKey {
        case number, title, state, draft, user, head
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case mergedAt = "merged_at"
        case autoMerge = "auto_merge"
    }
}

struct CheckRunDTO: Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String       // "completed", "in_progress", "queued"
    let conclusion: String?  // "success", "failure", "neutral", etc.
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case htmlURL = "html_url"
    }
}

struct ReviewRequestsDTO: Codable, Equatable, Sendable {
    let users: [GitHubUser]
    let teams: [GitHubTeam]
}

struct GitHubTeam: Codable, Equatable, Sendable {
    let slug: String
    let name: String
}

// MARK: - Comment DTOs

struct IssueCommentDTO: Codable, Equatable, Sendable {
    let id: Int
    let user: GitHubUser
    let body: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ReviewCommentDTO: Codable, Equatable, Sendable {
    let id: Int
    let user: GitHubUser
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let path: String?

    enum CodingKeys: String, CodingKey {
        case id, user, body, path
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Review DTO

struct ReviewDTO: Codable, Equatable, Sendable {
    let id: Int
    let user: GitHubUser
    let state: String  // "APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED"
    let body: String?
    let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, user, state, body
        case submittedAt = "submitted_at"
    }
}

// MARK: - Commit DTO

struct CommitDTO: Codable, Equatable, Sendable {
    let sha: String
    let commit: CommitInfo

    struct CommitInfo: Codable, Equatable, Sendable {
        let message: String
        let author: CommitAuthor?
    }

    struct CommitAuthor: Codable, Equatable, Sendable {
        let name: String
        let date: Date?
    }
}

import Foundation

// MARK: - Core Domain Enums

enum PRState: String, Codable, Sendable {
    case open, draft, merged, closed, queued
}

enum PRRole: String, Codable, Sendable {
    case authored, reviewing
}

enum ReviewStatus: String, Codable, Sendable {
    case pending, approved, changesRequested, commented
}

/// Detailed review summary tracking individual reviewer approvals.
/// Excludes team-based reviewers from the counts.
struct ReviewSummary: Codable, Equatable, Sendable {
    let totalReviewers: Int      // Number of individual (non-team) requested reviewers
    let approvedCount: Int       // How many have approved
    let changesRequestedCount: Int
    let commentedCount: Int

    /// The overall status derived from individual review states.
    var status: ReviewStatus {
        if changesRequestedCount > 0 { return .changesRequested }
        if totalReviewers == 0 { return .pending }
        if approvedCount >= totalReviewers { return .approved }
        if approvedCount > 0 || commentedCount > 0 { return .commented }
        return .pending
    }

    /// Human-readable label like "Approved 2/2" or "1/2 approved"
    var displayLabel: String {
        if totalReviewers == 0 { return "No reviewers" }
        if changesRequestedCount > 0 {
            return "Changes requested"
        }
        if approvedCount >= totalReviewers {
            return "Approved \(approvedCount)/\(totalReviewers)"
        }
        if approvedCount > 0 {
            return "Approved \(approvedCount)/\(totalReviewers)"
        }
        return "Pending 0/\(totalReviewers)"
    }

    static let empty = ReviewSummary(totalReviewers: 0, approvedCount: 0, changesRequestedCount: 0, commentedCount: 0)
}

enum CheckStatus: String, Codable, Sendable {
    case pending, success, failure, notApplicable
}

enum PREventType: String, Codable, Sendable {
    case reviewRequested
    case reviewSubmitted
    case commentAdded
    case checkCompleted
    case prStateChanged
    case prMerged
    case newCommitPushed
    case enteredMergeQueue
    case mergeQueueFailed
}

enum Disposition: String, Codable, Sendable {
    case delivered, suppressed
}

// MARK: - Domain Structs

struct Repository: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let owner: String
    let name: String
    var fullName: String { "\(owner)/\(name)" }
    var sortOrder: Int
}

struct TrackedPR: Codable, Identifiable, Equatable, Sendable {
    let id: String  // "\(repo.fullName)#\(number)"
    let number: Int
    let title: String
    let repository: Repository
    let state: PRState
    let role: PRRole
    let reviewStatus: ReviewStatus
    let reviewSummary: ReviewSummary
    let sdkBuildStatus: CheckStatus?
    let latestEvent: PREvent?
    let updatedAt: Date
}

struct PREvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let prIdentifier: String  // TrackedPR.id
    let prTitle: String
    let repository: Repository
    let eventType: PREventType
    let timestamp: Date
    let summary: String
}

// MARK: - Filtering

struct FilteringRule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let priority: Int
    var isEnabled: Bool
    let predicate: FilterPredicate
}

enum FilterPredicate: Codable, Equatable, Sendable {
    case eventType(PREventType)
    case ciCheck(checkName: String, conclusion: String?)
    case prRole(PRRole)
    case compound([FilterPredicate], mode: LogicalMode)

    enum LogicalMode: String, Codable, Sendable {
        case allOf, anyOf
    }

    // MARK: - Custom Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case eventType
        case checkName
        case conclusion
        case role
        case predicates
        case mode
    }

    private enum PredicateType: String, Codable {
        case eventType
        case ciCheck
        case prRole
        case compound
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .eventType(let eventType):
            try container.encode(PredicateType.eventType, forKey: .type)
            try container.encode(eventType, forKey: .eventType)
        case .ciCheck(let checkName, let conclusion):
            try container.encode(PredicateType.ciCheck, forKey: .type)
            try container.encode(checkName, forKey: .checkName)
            try container.encodeIfPresent(conclusion, forKey: .conclusion)
        case .prRole(let role):
            try container.encode(PredicateType.prRole, forKey: .type)
            try container.encode(role, forKey: .role)
        case .compound(let predicates, let mode):
            try container.encode(PredicateType.compound, forKey: .type)
            try container.encode(predicates, forKey: .predicates)
            try container.encode(mode, forKey: .mode)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PredicateType.self, forKey: .type)
        switch type {
        case .eventType:
            let eventType = try container.decode(PREventType.self, forKey: .eventType)
            self = .eventType(eventType)
        case .ciCheck:
            let checkName = try container.decode(String.self, forKey: .checkName)
            let conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
            self = .ciCheck(checkName: checkName, conclusion: conclusion)
        case .prRole:
            let role = try container.decode(PRRole.self, forKey: .role)
            self = .prRole(role)
        case .compound:
            let predicates = try container.decode([FilterPredicate].self, forKey: .predicates)
            let mode = try container.decode(LogicalMode.self, forKey: .mode)
            self = .compound(predicates, mode: mode)
        }
    }
}

// MARK: - Notification History

struct NotificationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let prTitle: String
    let prIdentifier: String  // e.g. "aws/aws-sdk-java-v2#7290" for linking
    let prNumber: Int
    let repository: Repository
    let eventType: PREventType
    let summary: String       // e.g. "aws-sdk-pr-build: success"
    let disposition: Disposition
    let matchedRuleName: String?
    let reason: String?  // Populated in debug mode
    var isRead: Bool = false
}

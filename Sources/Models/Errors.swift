import Foundation

// MARK: - Error Taxonomy

enum GhBonkError: Error, LocalizedError {
    // Network
    case networkUnavailable
    case httpError(statusCode: Int, body: String?)
    case rateLimited(resetDate: Date)
    case maxRetriesExceeded(underlyingError: Error)

    // Auth
    case tokenInvalid
    case tokenExpired
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)

    // Persistence
    case dataCorrupted(filename: String, underlyingError: Error)
    case writeError(filename: String, underlyingError: Error)

    // Validation
    case repositoryNotFound(fullName: String)
    case repositoryNotAccessible(fullName: String)
    case pollingIntervalTooShort(provided: TimeInterval, minimum: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Network is unavailable."
        case .httpError(let statusCode, _):
            return "HTTP error with status code \(statusCode)."
        case .rateLimited(let resetDate):
            return "Rate limited by GitHub. Resets at \(resetDate)."
        case .maxRetriesExceeded:
            return "Maximum retries exceeded."
        case .tokenInvalid:
            return "GitHub token is invalid."
        case .tokenExpired:
            return "GitHub token has expired."
        case .keychainReadFailed(let status):
            return "Failed to read from Keychain (status: \(status))."
        case .keychainWriteFailed(let status):
            return "Failed to write to Keychain (status: \(status))."
        case .dataCorrupted(let filename, _):
            return "Data file '\(filename)' is corrupted."
        case .writeError(let filename, _):
            return "Failed to write file '\(filename)'."
        case .repositoryNotFound(let fullName):
            return "Repository '\(fullName)' not found."
        case .repositoryNotAccessible(let fullName):
            return "Repository '\(fullName)' is not accessible with the current token."
        case .pollingIntervalTooShort(let provided, let minimum):
            return "Polling interval \(provided)s is below minimum of \(minimum)s."
        }
    }
}

// MARK: - Retry Policy

struct RetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let multiplier: Double

    init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1.0, multiplier: Double = 2.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
    }

    func delay(for attempt: Int) -> TimeInterval {
        baseDelay * pow(multiplier, Double(attempt))
    }
}

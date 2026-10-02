import Foundation

// MARK: - Filter Decision

/// The result of evaluating filtering rules against a PR event.
struct FilterDecision: Sendable {
    let disposition: Disposition
    let matchedRule: FilteringRule?
    let reason: String
}

// MARK: - Filter Engine

/// Evaluates filtering rules in priority order against a PR event.
///
/// Uses an ALLOWLIST model: if the event matches any enabled rule, it is delivered.
/// If no enabled rule matches, the event is suppressed.
///
/// This means each rule represents a type of notification the user wants to receive.
/// Disabling a rule suppresses that category of notification.
struct FilterEngine {

    /// Evaluates rules in priority order. First matching enabled rule delivers the event.
    /// If no enabled rule matches, the event is suppressed.
    ///
    /// - Parameters:
    ///   - event: The PR event to evaluate.
    ///   - prRole: The role of the current user relative to the PR (authored/reviewing).
    ///   - rules: All filtering rules (enabled and disabled).
    ///   - debugMode: When true, the reason field contains detailed explanations.
    /// - Returns: A `FilterDecision` indicating whether the event should be delivered or suppressed.
    static func evaluate(
        event: PREvent,
        prRole: PRRole,
        rules: [FilteringRule],
        debugMode: Bool
    ) -> FilterDecision {
        let sortedRules = rules.sorted { $0.priority < $1.priority }

        for rule in sortedRules {
            if matches(predicate: rule.predicate, event: event, prRole: prRole) {
                if rule.isEnabled {
                    // Matched an enabled rule — deliver
                    let reason: String
                    if debugMode {
                        reason = "Allowed by \"\(rule.name)\" (priority \(rule.priority)): \(rule.description)"
                    } else {
                        reason = rule.name
                    }
                    return FilterDecision(
                        disposition: .delivered,
                        matchedRule: rule,
                        reason: reason
                    )
                } else {
                    // Matched a disabled rule — suppress with explanation
                    let reason: String
                    if debugMode {
                        reason = "Suppressed: rule \"\(rule.name)\" is disabled (priority \(rule.priority))"
                    } else {
                        reason = "\(rule.name) (disabled)"
                    }
                    return FilterDecision(
                        disposition: .suppressed,
                        matchedRule: rule,
                        reason: reason
                    )
                }
            }
        }

        // No rule matched at all — suppress (unknown event type, no rule covers it)
        let reason = debugMode
            ? "Suppressed: no rule matches this event (type: \(event.eventType.rawValue), role: \(prRole.rawValue))"
            : "No matching rule"
        return FilterDecision(
            disposition: .suppressed,
            matchedRule: nil,
            reason: reason
        )
    }

    // MARK: - Predicate Matching

    /// Recursively evaluates a `FilterPredicate` against an event and role context.
    static func matches(
        predicate: FilterPredicate,
        event: PREvent,
        prRole: PRRole
    ) -> Bool {
        switch predicate {
        case .eventType(let type):
            return event.eventType == type

        case .ciCheck(let checkName, let conclusion):
            guard event.eventType == .checkCompleted else { return false }
            // Empty checkName matches any check
            if !checkName.isEmpty {
                guard event.summary.contains(checkName) else { return false }
            }
            if let conclusion {
                return event.summary.lowercased().contains(conclusion.lowercased())
            }
            return true

        case .prRole(let role):
            return prRole == role

        case .compound(let predicates, let mode):
            switch mode {
            case .allOf:
                return predicates.allSatisfy { matches(predicate: $0, event: event, prRole: prRole) }
            case .anyOf:
                return predicates.contains { matches(predicate: $0, event: event, prRole: prRole) }
            }
        }
    }
}

import Foundation
import Testing
@testable import ghBonk

// MARK: - FilterEngine Property Tests (Allowlist Model)

@Suite("FilterEngine Property Tests")
struct FilterEnginePropertyTests {

    private static let testRepo = Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0)

    private static func makeEvent(eventType: PREventType = .checkCompleted, summary: String = "check: result") -> PREvent {
        PREvent(id: UUID(), prIdentifier: "aws/aws-sdk-java-v2#42", prTitle: "Fix",
                repository: testRepo, eventType: eventType, timestamp: Date(), summary: summary)
    }

    private static func makeRule(name: String = "R", priority: Int = 1, isEnabled: Bool = true,
                                  predicate: FilterPredicate = .eventType(.checkCompleted)) -> FilteringRule {
        FilteringRule(id: UUID(), name: name, description: "desc", priority: priority,
                      isEnabled: isEnabled, predicate: predicate)
    }

    // MARK: - Property 10: Priority ordering (first match wins)

    @Test("Priority ordering: lowest number wins", arguments: [(1, 5), (0, 10), (3, 7), (99, 100)])
    func priorityOrderingLowestWins(priorities: (Int, Int)) {
        let (winnerP, loserP) = priorities
        let event = Self.makeEvent(eventType: .reviewRequested)
        let winner = Self.makeRule(name: "Winner", priority: winnerP, predicate: .eventType(.reviewRequested))
        let loser = Self.makeRule(name: "Loser", priority: loserP, predicate: .eventType(.reviewRequested))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [loser, winner], debugMode: false)
        #expect(decision.matchedRule?.name == "Winner")
    }

    @Test("Priority ordering consistent regardless of input order", arguments: PREventType.allCases)
    func priorityConsistent(eventType: PREventType) {
        let event = Self.makeEvent(eventType: eventType)
        let a = Self.makeRule(name: "A", priority: 2, predicate: .eventType(eventType))
        let b = Self.makeRule(name: "B", priority: 8, predicate: .eventType(eventType))
        for order in [[a, b], [b, a]] {
            let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: order, debugMode: false)
            #expect(decision.matchedRule?.name == "A")
        }
    }

    // MARK: - Property 11: Toggle independence

    @Test("Toggling one rule doesn't change others", arguments: [(3, 0), (3, 1), (5, 2), (5, 4)])
    func toggleIndependence(config: (Int, Int)) {
        let (count, idx) = config
        var rules: [FilteringRule] = (0..<count).map {
            Self.makeRule(name: "R\($0)", priority: $0, isEnabled: $0 % 2 == 0, predicate: .eventType(.checkCompleted))
        }
        let original = rules.map(\.isEnabled)
        rules[idx].isEnabled.toggle()
        for i in 0..<count where i != idx {
            #expect(rules[i].isEnabled == original[i])
        }
    }

    // MARK: - Property 14: Debug mode annotations

    @Test("Debug: delivered events annotated with rule name", arguments: PREventType.allCases)
    func debugDeliveredAnnotation(eventType: PREventType) {
        let event = Self.makeEvent(eventType: eventType)
        let rule = Self.makeRule(name: "Allow \(eventType.rawValue)", predicate: .eventType(eventType))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: true)
        #expect(decision.disposition == .delivered)
        #expect(decision.reason.contains("Allow \(eventType.rawValue)"))
    }

    @Test("Debug: suppressed (no match) explains why", arguments: PREventType.allCases)
    func debugSuppressedNoMatch(eventType: PREventType) {
        let event = Self.makeEvent(eventType: eventType)
        // Rule for a different event type — won't match
        let otherType: PREventType = eventType == .prMerged ? .commentAdded : .prMerged
        let rule = Self.makeRule(predicate: .eventType(otherType))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: true)
        #expect(decision.disposition == .suppressed)
        #expect(decision.reason.contains("no rule matches"))
    }

    @Test("Debug: suppressed (disabled rule) names the rule")
    func debugSuppressedDisabled() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(name: "Silenced", isEnabled: false, predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: true)
        #expect(decision.disposition == .suppressed)
        #expect(decision.reason.contains("Silenced"))
        #expect(decision.reason.contains("disabled"))
    }

    // MARK: - Default Filters Integration

    @Test("Default filters deliver comments on authored PRs")
    func defaultFiltersComments() {
        let event = Self.makeEvent(eventType: .commentAdded, summary: "Someone commented")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: rules, debugMode: false)
        #expect(decision.disposition == .delivered)
        #expect(decision.matchedRule?.name == "Comments on my PRs")
    }

    @Test("Default filters suppress SonarCloud")
    func defaultFiltersSonarCloud() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "SonarCloud Code Analysis: failure")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: rules, debugMode: false)
        #expect(decision.disposition == .suppressed)
        #expect(decision.matchedRule?.name == "SonarCloud results")
    }

    @Test("Default filters deliver SDK Build success")
    func defaultFiltersSDKSuccess() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "aws-sdk-pr-build: success")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: rules, debugMode: false)
        #expect(decision.disposition == .delivered)
        #expect(decision.matchedRule?.name == "SDK Build success")
    }

    @Test("Default filters deliver CI failure on authored PR")
    func defaultFiltersCIFailure() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "Unit Tests: failure")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: rules, debugMode: false)
        #expect(decision.disposition == .delivered)
        #expect(decision.matchedRule?.name == "CI failures (non-SonarCloud)")
    }

    @Test("Default filters suppress other CI successes")
    func defaultFiltersCISuccessSuppressed() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "lint: success")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: rules, debugMode: false)
        #expect(decision.disposition == .suppressed)
        #expect(decision.matchedRule?.name == "Other CI successes")
    }

    @Test("Default filters deliver review assignment")
    func defaultFiltersReviewAssigned() {
        let event = Self.makeEvent(eventType: .reviewRequested, summary: "assigned")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .reviewing, rules: rules, debugMode: false)
        #expect(decision.disposition == .delivered)
        #expect(decision.matchedRule?.name == "Assigned as reviewer")
    }

    @Test("Default filters deliver new commits on reviewing PR")
    func defaultFiltersNewCommits() {
        let event = Self.makeEvent(eventType: .newCommitPushed, summary: "Author pushed 2 new commits")
        let rules = DefaultFilters.create()
        let decision = FilterEngine.evaluate(event: event, prRole: .reviewing, rules: rules, debugMode: false)
        #expect(decision.disposition == .delivered)
        #expect(decision.matchedRule?.name == "Author pushed commits")
    }
}

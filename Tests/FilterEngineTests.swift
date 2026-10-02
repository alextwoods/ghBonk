import Foundation
import Testing
@testable import ghBonk

// MARK: - FilterEngine Tests (Allowlist Model)

@Suite("FilterEngine Tests")
struct FilterEngineTests {

    // MARK: - Test Helpers

    private static let testRepo = Repository(id: UUID(), owner: "aws", name: "aws-sdk-java-v2", sortOrder: 0)

    private static func makeEvent(
        eventType: PREventType = .checkCompleted,
        summary: String = "Build SDK / aws-sdk-pr-build (pull_request): failure"
    ) -> PREvent {
        PREvent(id: UUID(), prIdentifier: "aws/aws-sdk-java-v2#42", prTitle: "Fix bug",
                repository: testRepo, eventType: eventType, timestamp: Date(), summary: summary)
    }

    private static func makeRule(
        name: String = "Test Rule", description: String = "A rule", priority: Int = 1,
        isEnabled: Bool = true, predicate: FilterPredicate = .eventType(.checkCompleted)
    ) -> FilteringRule {
        FilteringRule(id: UUID(), name: name, description: description,
                      priority: priority, isEnabled: isEnabled, predicate: predicate)
    }

    // MARK: - Allowlist Basics

    @Test("No rules → event is suppressed")
    func noRulesSuppresses() {
        let event = Self.makeEvent()
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [], debugMode: false)
        #expect(decision.disposition == .suppressed)
    }

    @Test("Matching enabled rule → delivered")
    func matchingEnabledRuleDelivers() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .delivered)
        #expect(decision.matchedRule?.name == "Test Rule")
    }

    @Test("Matching disabled rule → suppressed with reason")
    func matchingDisabledRuleSuppresses() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(isEnabled: false, predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .suppressed)
        #expect(decision.matchedRule?.name == "Test Rule")
    }

    @Test("Non-matching rule → suppressed (no match)")
    func nonMatchingSuppresses() {
        let event = Self.makeEvent(eventType: .prMerged)
        let rule = Self.makeRule(predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .suppressed)
        #expect(decision.matchedRule == nil)
    }

    // MARK: - Priority

    @Test("First matching rule wins (lower priority number)")
    func priorityOrdering() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule1 = Self.makeRule(name: "High", priority: 1, isEnabled: true, predicate: .eventType(.commentAdded))
        let rule2 = Self.makeRule(name: "Low", priority: 10, isEnabled: true, predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule2, rule1], debugMode: false)
        #expect(decision.matchedRule?.name == "High")
    }

    @Test("Disabled higher-priority rule suppresses before lower-priority enabled rule can deliver")
    func disabledHighPriorityBlocksDelivery() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let disabledRule = Self.makeRule(name: "Disabled", priority: 1, isEnabled: false, predicate: .eventType(.commentAdded))
        let enabledRule = Self.makeRule(name: "Enabled", priority: 5, isEnabled: true, predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [enabledRule, disabledRule], debugMode: false)
        #expect(decision.disposition == .suppressed)
        #expect(decision.matchedRule?.name == "Disabled")
    }

    // MARK: - Compound Predicates

    @Test("Compound allOf matches when all sub-predicates match")
    func compoundAllOf() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(predicate: .compound([.eventType(.commentAdded), .prRole(.authored)], mode: .allOf))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .delivered)
    }

    @Test("Compound allOf fails when one sub-predicate doesn't match")
    func compoundAllOfPartial() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(predicate: .compound([.eventType(.commentAdded), .prRole(.reviewing)], mode: .allOf))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .suppressed)
    }

    @Test("Compound anyOf matches when at least one sub-predicate matches")
    func compoundAnyOf() {
        let event = Self.makeEvent(eventType: .prMerged)
        let rule = Self.makeRule(predicate: .compound([.eventType(.prStateChanged), .eventType(.prMerged)], mode: .anyOf))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .delivered)
    }

    // MARK: - CI Check Predicate

    @Test("ciCheck with specific name and conclusion matches")
    func ciCheckSpecific() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "aws-sdk-pr-build: success")
        let rule = Self.makeRule(predicate: .compound([
            .eventType(.checkCompleted), .ciCheck(checkName: "aws-sdk-pr-build", conclusion: "success")
        ], mode: .allOf))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .delivered)
    }

    @Test("ciCheck with empty name matches any check")
    func ciCheckEmptyName() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "random-check: failure")
        let rule = Self.makeRule(predicate: .compound([
            .eventType(.checkCompleted), .ciCheck(checkName: "", conclusion: "failure")
        ], mode: .allOf))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .delivered)
    }

    @Test("ciCheck with wrong conclusion doesn't match")
    func ciCheckWrongConclusion() {
        let event = Self.makeEvent(eventType: .checkCompleted, summary: "aws-sdk-pr-build: failure")
        let rule = Self.makeRule(predicate: .ciCheck(checkName: "aws-sdk-pr-build", conclusion: "success"))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: false)
        #expect(decision.disposition == .suppressed)
    }

    // MARK: - Debug Mode

    @Test("Debug mode: delivered event has detailed reason")
    func debugDelivered() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(name: "My Rule", description: "Desc", predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: true)
        #expect(decision.disposition == .delivered)
        #expect(decision.reason.contains("My Rule"))
        #expect(decision.reason.contains("Allowed"))
    }

    @Test("Debug mode: suppressed (disabled rule) has detailed reason")
    func debugSuppressedDisabled() {
        let event = Self.makeEvent(eventType: .commentAdded)
        let rule = Self.makeRule(name: "Off Rule", isEnabled: false, predicate: .eventType(.commentAdded))
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [rule], debugMode: true)
        #expect(decision.disposition == .suppressed)
        #expect(decision.reason.contains("Off Rule"))
        #expect(decision.reason.contains("disabled"))
    }

    @Test("Debug mode: suppressed (no match) has detailed reason")
    func debugSuppressedNoMatch() {
        let event = Self.makeEvent(eventType: .prMerged)
        let decision = FilterEngine.evaluate(event: event, prRole: .authored, rules: [], debugMode: true)
        #expect(decision.disposition == .suppressed)
        #expect(decision.reason.contains("no rule matches"))
    }
}

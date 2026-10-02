import Foundation
import Testing
@testable import ghBonk

// MARK: - Property 4: Exponential Backoff Delay
// **Validates: Requirements 3.4**
// For any attempt n in [0,2], delay equals `baseDelay * multiplier^n`.

@Suite("RetryPolicy Exponential Backoff Tests")
struct RetryPolicyTests {

    // MARK: - Default Policy (baseDelay=1.0, multiplier=2.0)

    @Test("Default policy: delay equals 1.0 * 2^n", arguments: [
        (0, 1.0),
        (1, 2.0),
        (2, 4.0),
    ] as [(Int, Double)])
    func defaultPolicyDelay(attempt: Int, expectedDelay: Double) {
        let policy = RetryPolicy()
        let delay = policy.delay(for: attempt)
        #expect(delay == expectedDelay, "Expected delay for attempt \(attempt) to be \(expectedDelay), got \(delay)")
    }

    // MARK: - Custom Policy (baseDelay=0.5, multiplier=3.0)

    @Test("Custom policy (base=0.5, mult=3.0): delay equals 0.5 * 3^n", arguments: [
        (0, 0.5),
        (1, 1.5),
        (2, 4.5),
    ] as [(Int, Double)])
    func customPolicyDelay(attempt: Int, expectedDelay: Double) {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, multiplier: 3.0)
        let delay = policy.delay(for: attempt)
        #expect(delay == expectedDelay, "Expected delay for attempt \(attempt) to be \(expectedDelay), got \(delay)")
    }

    // MARK: - Property: delay(n) == baseDelay * multiplier^n

    @Test("Property: for any valid config, delay(n) == baseDelay * multiplier^n", arguments: [
        (1.0, 2.0, 0),
        (1.0, 2.0, 1),
        (1.0, 2.0, 2),
        (0.5, 3.0, 0),
        (0.5, 3.0, 1),
        (0.5, 3.0, 2),
        (2.0, 1.5, 0),
        (2.0, 1.5, 1),
        (2.0, 1.5, 2),
        (0.1, 10.0, 0),
        (0.1, 10.0, 1),
        (0.1, 10.0, 2),
        (5.0, 2.0, 0),
        (5.0, 2.0, 1),
        (5.0, 2.0, 2),
        (0.25, 4.0, 0),
        (0.25, 4.0, 1),
        (0.25, 4.0, 2),
    ] as [(Double, Double, Int)])
    func exponentialBackoffProperty(baseDelay: Double, multiplier: Double, attempt: Int) {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: baseDelay, multiplier: multiplier)
        let actual = policy.delay(for: attempt)
        let expected = baseDelay * pow(multiplier, Double(attempt))
        #expect(
            abs(actual - expected) < 1e-10,
            "delay(for: \(attempt)) with baseDelay=\(baseDelay), multiplier=\(multiplier): expected \(expected), got \(actual)"
        )
    }
}

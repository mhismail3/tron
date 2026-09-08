import Foundation
import Testing
@testable import TronMobile

struct GatewayRecoveryPolicyTests {
    @Test("automatic recovery stops after three attempts until explicit retry")
    func automaticBudgetStopsAndRearms() {
        var budget = GatewayRecoveryBudget()
        let first = budget.beginAutomaticAttempt()
        let second = budget.beginAutomaticAttempt()
        let third = budget.beginAutomaticAttempt()
        let fourth = budget.beginAutomaticAttempt()
        #expect(first)
        #expect(second)
        #expect(third)
        #expect(!fourth)
        #expect(budget.exhausted)

        budget.rearmForExplicitRetry()
        #expect(!budget.exhausted)
        #expect(!budget.nonRetryableStopped)
        let retry = budget.beginAutomaticAttempt()
        #expect(retry)
    }

    @Test("rapid hello failure does not reset the budget")
    func rapidEpochFailureRetainsBudget() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let began = budget.beginAutomaticAttempt()
        #expect(began)
        budget.markConnected(at: now)
        budget.markTransportFailure(code: "ping_timeout", at: now + .seconds(1))
        #expect(budget.automaticAttempts == 1)
        #expect(budget.firstFailureCode == "ping_timeout")
    }

    @Test("stable epoch resets the budget before consuming the new failure")
    func stableEpochResetsBudget() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let first = budget.beginAutomaticAttempt()
        let second = budget.beginAutomaticAttempt()
        #expect(first)
        #expect(second)
        budget.markConnected(at: now)
        budget.markTransportFailure(code: "disconnected", at: now + GatewayRecoveryBudget.stableEpochDuration)
        #expect(budget.automaticAttempts == 0)
        #expect(!budget.exhausted)
        #expect(budget.firstFailureCode == "disconnected")
        let next = budget.beginAutomaticAttempt()
        #expect(next)
    }

    @Test("background retirement preserves attempts without recording a fault")
    func backgroundRetirementPreservesBudget() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let began = budget.beginAutomaticAttempt()
        #expect(began)
        budget.markConnected(at: now)
        budget.markConnectionRetired(at: now + .seconds(1))
        #expect(budget.automaticAttempts == 0)
        #expect(budget.firstFailureCode == nil)
        #expect(budget.connectedAt == nil)
    }

    @Test("intentional short retirements never forgive preceding faults or an exhausted budget")
    func intentionalRetirementPreservesRealFailures() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let first = budget.beginAutomaticAttempt()
        #expect(first)
        budget.markTransportFailure(code: "timeout", at: now)
        for _ in 0..<10 {
            let admitted = budget.beginAutomaticAttempt()
            #expect(admitted)
            budget.markConnected(at: now)
            budget.markConnectionRetired(at: now + .seconds(1))
            #expect(budget.automaticAttempts == 1)
            #expect(budget.firstFailureCode == "timeout")
        }
        for _ in 0..<2 {
            let admitted = budget.beginAutomaticAttempt()
            #expect(admitted)
            budget.markConnected(at: now)
            budget.markTransportFailure(code: "ping_timeout", at: now + .seconds(1))
            budget.markConnectionRetired(at: now + .seconds(2))
        }
        #expect(budget.exhausted)
        let blocked = budget.beginAutomaticAttempt()
        #expect(!blocked)
        #expect(budget.firstFailureCode == "timeout")
    }

    @Test("nonretryable failure remains stopped until explicit retry")
    func nonRetryableFailureLatches() {
        var budget = GatewayRecoveryBudget()
        budget.markNonRetryableFailure(code: "protocol_mismatch")
        #expect(budget.nonRetryableStopped)
        let stopped = budget.beginAutomaticAttempt()
        #expect(!stopped)
        budget.rearmForExplicitRetry()
        #expect(!budget.nonRetryableStopped)
        let retried = budget.beginAutomaticAttempt()
        #expect(retried)
    }
}

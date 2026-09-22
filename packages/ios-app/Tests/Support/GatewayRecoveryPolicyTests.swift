import Foundation
import Testing
@testable import TronMobile

struct GatewayRecoveryPolicyTests {
    @Test("automatic recovery stops after three attempts until explicit retry")
    func automaticBudgetStopsAndRearms() {
        var budget = GatewayRecoveryBudget()
        let first = budget.beginAutomaticAttemptID() != nil
        let second = budget.beginAutomaticAttemptID() != nil
        let third = budget.beginAutomaticAttemptID() != nil
        let fourth = budget.beginAutomaticAttemptID() != nil
        #expect(first)
        #expect(second)
        #expect(third)
        #expect(!fourth)
        #expect(budget.exhausted)

        budget.rearmForExplicitRetry()
        #expect(!budget.exhausted)
        #expect(!budget.nonRetryableStopped)
        let retry = budget.beginAutomaticAttemptID() != nil
        #expect(retry)
    }

    @Test("late intentional settlement cannot refund a successor attempt")
    func lateAttemptSettlementIsIdentityQualified() {
        var budget = GatewayRecoveryBudget()
        let predecessor = budget.beginAutomaticAttemptID()
        #expect(predecessor != nil)
        let settledPredecessor = budget.settleAutomaticAttempt(predecessor!, intentionalRetirement: true)
        #expect(settledPredecessor)
        let successor = budget.beginAutomaticAttemptID()
        #expect(successor != nil)
        #expect(budget.automaticAttempts == 1)
        let lateSettlement = budget.settleAutomaticAttempt(predecessor!, intentionalRetirement: true)
        #expect(!lateSettlement)
        #expect(budget.automaticAttempts == 1)
        let settledSuccessor = budget.settleAutomaticAttempt(successor!, intentionalRetirement: false)
        #expect(settledSuccessor)
    }

    @Test("rapid hello failure does not reset the budget")
    func rapidEpochFailureRetainsBudget() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let began = budget.beginAutomaticAttemptID() != nil
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
        let first = budget.beginAutomaticAttemptID() != nil
        let second = budget.beginAutomaticAttemptID() != nil
        #expect(first)
        #expect(second)
        budget.markConnected(at: now)
        budget.markStableProof(at: now + GatewayRecoveryBudget.stableEpochDuration)
        budget.markTransportFailure(code: "disconnected", at: now + GatewayRecoveryBudget.stableEpochDuration, stableProof: true)
        #expect(budget.automaticAttempts == 0)
        #expect(!budget.exhausted)
        #expect(budget.firstFailureCode == "disconnected")
        let next = budget.beginAutomaticAttemptID() != nil
        #expect(next)
    }

    @Test("background retirement preserves attempts without recording a fault")
    func backgroundRetirementPreservesBudget() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let began = budget.beginAutomaticAttemptID() != nil
        #expect(began)
        budget.markConnected(at: now)
        budget.markConnectionRetired(at: now + .seconds(1), stableProof: false)
        #expect(budget.automaticAttempts == 0)
        #expect(budget.firstFailureCode == nil)
        #expect(budget.connectedAt == nil)
    }

    @Test("intentional short retirements never forgive preceding faults or an exhausted budget")
    func intentionalRetirementPreservesRealFailures() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let first = budget.beginAutomaticAttemptID() != nil
        #expect(first)
        budget.markTransportFailure(code: "timeout", at: now)
        for _ in 0..<10 {
            let admitted = budget.beginAutomaticAttemptID() != nil
            #expect(admitted)
            budget.markConnected(at: now)
            budget.markConnectionRetired(at: now + .seconds(1), stableProof: false)
            #expect(budget.automaticAttempts == 1)
            #expect(budget.firstFailureCode == "timeout")
        }
        for _ in 0..<2 {
            let admitted = budget.beginAutomaticAttemptID() != nil
            #expect(admitted)
            budget.markConnected(at: now)
            budget.markTransportFailure(code: "ping_timeout", at: now + .seconds(1))
            budget.markConnectionRetired(at: now + .seconds(2), stableProof: false)
        }
        #expect(budget.exhausted)
        let blocked = budget.beginAutomaticAttemptID() != nil
        #expect(!blocked)
        #expect(budget.firstFailureCode == "timeout")
    }

    @MainActor
    @Test("focused and dashboard owners share one profile allowance")
    func sharedAllowanceRetainsFailureAcrossRoleHandoff() {
        let store = GatewayRecoveryAllowanceStore()
        var budget = store["profile", default: GatewayRecoveryBudget()]
        let first = budget.beginAutomaticAttemptID() != nil
        #expect(first)
        budget.markTransportFailure(code: "timeout", at: ContinuousClock().now)
        store["profile"] = budget
        #expect(store["profile"]?.firstFailureCode == "timeout")
        budget = store["profile", default: GatewayRecoveryBudget()]
        let second = budget.beginAutomaticAttemptID() != nil
        let third = budget.beginAutomaticAttemptID() != nil
        let fourth = budget.beginAutomaticAttemptID() != nil
        #expect(second)
        #expect(third)
        #expect(!fourth)
        store["profile"] = budget
        #expect(store["profile"]?.exhausted == true)
    }

    @Test("path return clears a parked profile episode after one fallback")
    func pathReturnRevivesParkedEpisode() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        budget.beginRecoveryEpisode(at: now)
        budget.notePathHint(satisfied: false, at: now)
        #expect(budget.knownNoUsablePath)
        let firstFallback = budget.consumeFallbackVerification()
        let secondFallback = budget.consumeFallbackVerification()
        #expect(firstFallback)
        #expect(!secondFallback)
        #expect(budget.waitingForPath)
        #expect(!budget.isStopped)
        budget.notePathHint(satisfied: true, at: now)
        #expect(!budget.knownNoUsablePath)
        #expect(!budget.waitingForPath)
        let resumedFallback = budget.consumeFallbackVerification()
        #expect(resumedFallback)
    }

    @MainActor
    @Test("profile episode state does not poison another profile")
    func profileEpisodeStateIsolated() {
        let store = GatewayRecoveryAllowanceStore()
        var exhausted = GatewayRecoveryBudget()
        exhausted.stopRecoveryEpisode()
        store["A"] = exhausted
        var healthy = store["B", default: GatewayRecoveryBudget()]
        healthy.beginRecoveryEpisode(at: ContinuousClock().now)
        #expect(store["A"]?.isStopped == true)
        #expect(!healthy.isStopped)
        let admitted = healthy.beginAutomaticAttemptID() != nil
        #expect(admitted)
    }

    @Test("background and no-path pauses retain active recovery time without charging suspension")
    func pausedRecoveryRetainsActiveTimeOnly() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        budget.beginRecoveryEpisode(at: now)
        budget.pauseRecovery(at: now + .seconds(10))
        budget.resumeRecovery(at: now + .seconds(70))
        #expect(budget.activeRecoveryDuration(at: now + .seconds(80)) == .seconds(20))
        budget.notePathHint(satisfied: false, at: now + .seconds(80))
        #expect(budget.activeRecoveryDuration(at: now + .seconds(180)) == .seconds(20))
    }

    @Test("a free maintenance hello cannot refund an earlier ordinary failure")
    func maintenanceRetirementCannotForgiveFailure() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        let admitted = budget.beginAutomaticAttemptID() != nil
        #expect(admitted)
        budget.markTransportFailure(code: "timeout", at: now)
        budget.markConnected(at: now + .seconds(1), chargedAttempt: false)
        budget.markConnectionRetired(at: now + .seconds(2), stableProof: false)
        #expect(budget.automaticAttempts == 1)
        #expect(budget.firstFailureCode == "timeout")
    }

    @Test("failure preserves consumed recovery time and path chatter cannot rearm a deadline stop")
    func recoveryTimeAndTerminalStopRemainOwned() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        budget.beginRecoveryEpisode(at: now)
        budget.markTransportFailure(code: "disconnected", at: now + .seconds(7))
        #expect(budget.activeRecoveryDuration(at: now + .seconds(10)) == .seconds(10))
        budget.markConnected(at: now + .seconds(11))
        #expect(budget.activeRecoveryDuration(at: now + .seconds(60)) == .seconds(11))
        budget.markTransportFailure(code: "disconnected", at: now + .seconds(61))
        #expect(budget.activeRecoveryDuration(at: now + .seconds(65)) == .seconds(15))
        budget.stopRecoveryEpisode()
        budget.notePathHint(satisfied: true, at: now + .seconds(66))
        budget.admitFreshForegroundVerification()
        #expect(budget.isStopped)
        let admitted = budget.beginAutomaticAttemptID() != nil
        #expect(!admitted)
    }

    @Test("hello does not clear the active recovery episode before stability")
    func provisionalHelloRetainsEpisodeDeadline() {
        var budget = GatewayRecoveryBudget()
        let now = ContinuousClock().now
        budget.beginRecoveryEpisode(at: now)
        _ = budget.beginAutomaticAttemptID()
        budget.markConnected(at: now)
        #expect(budget.recoveryEpisodeStartedAt == now)
        budget.markTransportFailure(code: "disconnected", at: now + .seconds(1))
        #expect(budget.recoveryEpisodeStartedAt == now)
    }

    @Test("nonretryable failure remains stopped until explicit retry")
    func nonRetryableFailureLatches() {
        var budget = GatewayRecoveryBudget()
        budget.markNonRetryableFailure(code: "protocol_mismatch")
        #expect(budget.nonRetryableStopped)
        let stopped = budget.beginAutomaticAttemptID() != nil
        #expect(!stopped)
        budget.rearmForExplicitRetry()
        #expect(!budget.nonRetryableStopped)
        let retried = budget.beginAutomaticAttemptID() != nil
        #expect(retried)
    }
}

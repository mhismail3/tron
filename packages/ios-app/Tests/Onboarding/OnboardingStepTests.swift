import Testing
@testable import TronMobile

/// `OnboardingStep` is a pure enum that backs the wizard's NavigationStack
/// and the `@AppStorage("onboardingStep")` resume marker. The tests here
/// pin the contract every other onboarding test and the View depend on:
///
///  - the default step is `.welcome` (fresh install),
///  - the persisted raw values are stable strings (so a TestFlight upgrade
///    that ships the same enum compiles a different binary keeps reading
///    the same `@AppStorage` key without losing position),
///  - `next()` and `previous()` traverse the canonical sequence,
///  - `.welcome.skipToPairing()` (power-user shortcut) lands directly on
///    `.pairing` skipping `.tailscale` and `.macInstall`,
///  - `.done` is terminal — both `next()` and `skipToPairing()` are no-ops.
///
/// The raw-value strings are also stamped into telemetry events
/// (`onboarding_step_completed { step }`), so a rename without a migration
/// would silently fragment the funnel in PostHog. Tests guard.
@Suite("OnboardingStep")
struct OnboardingStepTests {

    // MARK: - Defaults & raw values

    @Test("Default step is .welcome")
    func defaultIsWelcome() {
        // The implementation lives in the enum's `static let initial` so
        // the constructor never depends on a sentinel.
        #expect(OnboardingStep.initial == .welcome)
    }

    @Test("Raw values are stable strings (telemetry + AppStorage contract)")
    func rawValuesStable() {
        let expected: [(OnboardingStep, String)] = [
            (.welcome, "welcome"),
            (.tailscale, "tailscale"),
            (.macInstall, "macInstall"),
            (.pairing, "pairing"),
            (.provider, "provider"),
            (.telemetryConsent, "telemetryConsent"),
            (.notifications, "notifications"),
            (.done, "done"),
        ]
        for (step, raw) in expected {
            #expect(step.rawValue == raw,
                    "raw value drift on \(step) — telemetry funnel + AppStorage will fragment")
        }
    }

    @Test("All canonical cases are covered by CaseIterable")
    func allCasesCovered() {
        let all = OnboardingStep.allCases
        #expect(all.count == 8)
        #expect(all.first == .welcome)
        #expect(all.last == .done)
    }

    // MARK: - next() / previous()

    @Test("next() walks the canonical sequence")
    func nextWalksSequence() {
        #expect(OnboardingStep.welcome.next() == .tailscale)
        #expect(OnboardingStep.tailscale.next() == .macInstall)
        #expect(OnboardingStep.macInstall.next() == .pairing)
        #expect(OnboardingStep.pairing.next() == .provider)
        #expect(OnboardingStep.provider.next() == .telemetryConsent)
        #expect(OnboardingStep.telemetryConsent.next() == .notifications)
        #expect(OnboardingStep.notifications.next() == .done)
    }

    @Test("previous() walks the sequence in reverse")
    func previousWalksReverse() {
        #expect(OnboardingStep.tailscale.previous() == .welcome)
        #expect(OnboardingStep.macInstall.previous() == .tailscale)
        #expect(OnboardingStep.pairing.previous() == .macInstall)
        #expect(OnboardingStep.provider.previous() == .pairing)
        #expect(OnboardingStep.telemetryConsent.previous() == .provider)
        #expect(OnboardingStep.notifications.previous() == .telemetryConsent)
        #expect(OnboardingStep.done.previous() == .notifications)
    }

    @Test(".welcome.previous() stays on .welcome (no underflow)")
    func welcomePreviousIsNoOp() {
        #expect(OnboardingStep.welcome.previous() == .welcome)
    }

    @Test(".done.next() stays on .done (no overflow)")
    func doneNextIsNoOp() {
        #expect(OnboardingStep.done.next() == .done)
    }

    // MARK: - skipToPairing power-user shortcut

    @Test(".welcome.skipToPairing() lands on .pairing")
    func skipFromWelcome() {
        #expect(OnboardingStep.welcome.skipToPairing() == .pairing)
    }

    @Test(".tailscale.skipToPairing() also lands on .pairing")
    func skipFromTailscale() {
        // The 'I already have Tron running' button can be hit on welcome
        // OR after the user has stepped into tailscale and realized they
        // don't need the prereq.
        #expect(OnboardingStep.tailscale.skipToPairing() == .pairing)
    }

    @Test(".macInstall.skipToPairing() also lands on .pairing")
    func skipFromMacInstall() {
        #expect(OnboardingStep.macInstall.skipToPairing() == .pairing)
    }

    @Test("Skipping from later steps is a no-op (already past pairing)")
    func skipFromPostPairingIsNoOp() {
        #expect(OnboardingStep.pairing.skipToPairing() == .pairing)
        #expect(OnboardingStep.provider.skipToPairing() == .provider)
        #expect(OnboardingStep.notifications.skipToPairing() == .notifications)
        #expect(OnboardingStep.done.skipToPairing() == .done)
    }

    // MARK: - Phase classification

    @Test(".isPostPairing is true for steps after pairing")
    func postPairingClassification() {
        // Used by the migration helper to decide whether to display the
        // pairing-only resume state vs full onboarding.
        #expect(OnboardingStep.welcome.isPostPairing == false)
        #expect(OnboardingStep.tailscale.isPostPairing == false)
        #expect(OnboardingStep.macInstall.isPostPairing == false)
        #expect(OnboardingStep.pairing.isPostPairing == false)
        #expect(OnboardingStep.provider.isPostPairing == true)
        #expect(OnboardingStep.telemetryConsent.isPostPairing == true)
        #expect(OnboardingStep.notifications.isPostPairing == true)
        #expect(OnboardingStep.done.isPostPairing == true)
    }
}

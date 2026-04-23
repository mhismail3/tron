import Foundation
import Testing
@testable import TronMobile

/// `OnboardingMigrationDecider` is the pure-value helper that decides
/// whether an existing TestFlight install should be auto-marked as
/// onboarded on first launch with the new build.
///
/// **The contract**: a TestFlight user who already has a working
/// `connectionPresets[]` cached should NOT see the welcome wizard — they're
/// already paired. If their bearer token is now stale (because the server
/// flipped `auth.enforced=true` between releases), the existing
/// `.unauthorized` ConnectionStatusPill + re-pair sheet from Phase 3
/// surfaces the fix without dragging the user through the full wizard.
///
/// **Why a pure helper**: keeps the decision testable without standing up
/// `DependencyContainer` + UserDefaults + RPCClient. The caller (the app
/// initializer) wires the decision back into `@AppStorage`.
@Suite("OnboardingMigrationDecider")
struct OnboardingMigrationTests {

    // MARK: - Auto-mark decisions

    @Test("Fresh install: shouldAutoMarkComplete = false")
    func freshInstall() {
        let result = OnboardingMigrationDecider.shouldAutoMarkComplete(
            hasCompletedOnboarding: false,
            cachedPresetCount: 0
        )
        #expect(result == false)
    }

    @Test("Existing user with cached presets: shouldAutoMarkComplete = true")
    func existingUserWithPresets() {
        let result = OnboardingMigrationDecider.shouldAutoMarkComplete(
            hasCompletedOnboarding: false,
            cachedPresetCount: 2
        )
        #expect(result == true,
                "TestFlight users who already paired must skip onboarding")
    }

    @Test("Already-onboarded user: shouldAutoMarkComplete = false (idempotent)")
    func alreadyOnboarded() {
        let result = OnboardingMigrationDecider.shouldAutoMarkComplete(
            hasCompletedOnboarding: true,
            cachedPresetCount: 5
        )
        #expect(result == false,
                "Don't churn AppStorage if it's already true")
    }

    @Test("Already-onboarded with no presets: shouldAutoMarkComplete = false")
    func alreadyOnboardedNoPresets() {
        let result = OnboardingMigrationDecider.shouldAutoMarkComplete(
            hasCompletedOnboarding: true,
            cachedPresetCount: 0
        )
        #expect(result == false)
    }

    // MARK: - Apply

    @Test("apply(_:) writes the completion flag iff the decision is true")
    func applyPersistsCompletion() {
        let defaultsTrue = ephemeralDefaults()
        OnboardingMigrationDecider.apply(
            decision: true,
            defaults: defaultsTrue
        )
        #expect(defaultsTrue.bool(forKey: OnboardingState.completionStorageKey) == true)

        let defaultsFalse = ephemeralDefaults()
        OnboardingMigrationDecider.apply(
            decision: false,
            defaults: defaultsFalse
        )
        // No write — key remains false (UserDefaults default for bool).
        #expect(defaultsFalse.bool(forKey: OnboardingState.completionStorageKey) == false)
    }

    @Test("End-to-end: existing user with presets ends up flagged complete")
    func endToEnd() {
        let defaults = ephemeralDefaults()
        // Simulate a TestFlight upgrade: one cached preset, no completion flag.
        let preset = ConnectionPreset(id: "p1", label: "Mac", host: "100.64.0.1", port: 9847)
        let data = try! JSONEncoder().encode([preset])
        defaults.set(data, forKey: OnboardingState.cachedPresetsKey)

        let presetCount = OnboardingMigrationDecider.cachedPresetCount(defaults: defaults)
        #expect(presetCount == 1)

        let decision = OnboardingMigrationDecider.shouldAutoMarkComplete(
            hasCompletedOnboarding: defaults.bool(forKey: OnboardingState.completionStorageKey),
            cachedPresetCount: presetCount
        )
        #expect(decision == true)

        OnboardingMigrationDecider.apply(decision: decision, defaults: defaults)
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == true)
    }

    @Test("cachedPresetCount returns 0 for a defaults blob with no preset key")
    func cachedPresetCountEmpty() {
        let defaults = ephemeralDefaults()
        #expect(OnboardingMigrationDecider.cachedPresetCount(defaults: defaults) == 0)
    }

    @Test("cachedPresetCount returns 0 for corrupt preset blob (defensive)")
    func cachedPresetCountCorrupt() {
        let defaults = ephemeralDefaults()
        defaults.set(Data([0xFF, 0xFE, 0x00]), forKey: OnboardingState.cachedPresetsKey)
        #expect(OnboardingMigrationDecider.cachedPresetCount(defaults: defaults) == 0)
    }

    @Test("cachedPresetCount uses the same key as SettingsState (canary)")
    func cachedPresetsKeyCanary() {
        // The migration helper reads the same key SettingsState writes —
        // a refactor changing one without the other would silently break.
        #expect(OnboardingState.cachedPresetsKey == SettingsState.cachedPresetsKey)
    }

    // MARK: - Helpers

    private func ephemeralDefaults() -> UserDefaults {
        let suiteName = "test.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

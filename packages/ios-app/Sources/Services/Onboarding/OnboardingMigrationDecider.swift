import Foundation

/// Pure-value helper that decides whether an existing TestFlight install
/// should be auto-marked as onboarded on first launch with the new build.
///
/// **The principle**: a TestFlight user who already has a working
/// `connectionPresets[]` cached in UserDefaults should NOT be dragged
/// through the welcome wizard. They're already paired. If their bearer
/// token is now stale (because the server flipped `auth.enforced=true`
/// between releases), the existing `.unauthorized` ConnectionStatusPill +
/// re-pair sheet from Phase 3 surfaces the fix without re-running onboarding.
///
/// **Why pure**: the decision composes a couple of simple inputs
/// (`hasCompletedOnboarding`, `cachedPresetCount`); pulling that out of
/// the app initializer makes it unit-testable without standing up
/// `DependencyContainer`, RPC, or real UserDefaults pollution.
///
/// **The migration is one-shot**: `apply` writes `onboardingComplete=true`
/// only when the decision is `true`; otherwise it is a no-op so we never
/// undo a user's explicit "rerun onboarding" reset.
enum OnboardingMigrationDecider {

    /// Decide whether to flip `onboardingComplete=true` for an existing user.
    /// True iff the user has not been marked complete AND has cached presets
    /// (proof they paired with a Mac at some point).
    static func shouldAutoMarkComplete(
        hasCompletedOnboarding: Bool,
        cachedPresetCount: Int
    ) -> Bool {
        return !hasCompletedOnboarding && cachedPresetCount > 0
    }

    /// Persist the decision. No-op when `decision == false` to avoid
    /// undoing a user's explicit reset.
    static func apply(decision: Bool, defaults: UserDefaults) {
        guard decision else { return }
        defaults.set(true, forKey: OnboardingState.completionStorageKey)
    }

    /// Read the cached `[ConnectionPreset]` count from UserDefaults. Returns
    /// 0 if the key is absent OR the blob is corrupt (defensive — corrupt
    /// blobs should not promote a fresh user past the wizard).
    static func cachedPresetCount(defaults: UserDefaults) -> Int {
        guard let data = defaults.data(forKey: OnboardingState.cachedPresetsKey),
              let presets = try? JSONDecoder().decode([ConnectionPreset].self, from: data) else {
            return 0
        }
        return presets.count
    }

    /// One-shot convenience: read the inputs from `defaults` and apply the
    /// decision. Returns the decision so the caller can log it.
    @discardableResult
    static func runMigrationIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let already = defaults.bool(forKey: OnboardingState.completionStorageKey)
        let presets = cachedPresetCount(defaults: defaults)
        let decision = shouldAutoMarkComplete(
            hasCompletedOnboarding: already,
            cachedPresetCount: presets
        )
        apply(decision: decision, defaults: defaults)
        return decision
    }
}

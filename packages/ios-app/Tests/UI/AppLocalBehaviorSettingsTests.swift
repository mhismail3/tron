import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("App-local behavior settings")
struct AppLocalBehaviorSettingsTests {
    @Test("retention defaults to the existing five-minute projection window and persists")
    func defaultAndPersistence() {
        let defaults = UserDefaults(suiteName: "AppLocalBehaviorSettingsTests.default")!
        defaults.removePersistentDomain(forName: "AppLocalBehaviorSettingsTests.default")

        let settings = AppLocalBehaviorSettings(defaults: defaults)
        #expect(settings.subagentRecentFinishedRetentionMinutes == 5)

        settings.subagentRecentFinishedRetentionMinutes = 3
        let reloaded = AppLocalBehaviorSettings(defaults: defaults)
        #expect(reloaded.subagentRecentFinishedRetentionMinutes == 3)
    }

    @Test("retention is bounded to the supported zero through five range")
    func boundedRange() {
        let defaults = UserDefaults(suiteName: "AppLocalBehaviorSettingsTests.bounds")!
        defaults.removePersistentDomain(forName: "AppLocalBehaviorSettingsTests.bounds")
        let settings = AppLocalBehaviorSettings(defaults: defaults)

        settings.subagentRecentFinishedRetentionMinutes = 0
        #expect(settings.subagentRecentFinishedRetentionMinutes == 0)
        settings.subagentRecentFinishedRetentionMinutes = 5
        #expect(settings.subagentRecentFinishedRetentionMinutes == 5)
        settings.subagentRecentFinishedRetentionMinutes = 99
        #expect(settings.subagentRecentFinishedRetentionMinutes == 5)
    }
}

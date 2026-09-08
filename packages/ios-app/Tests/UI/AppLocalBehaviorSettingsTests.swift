import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("App-local behavior settings")
struct AppLocalBehaviorSettingsTests {
    @Test("retention defaults to five minutes and every supported choice persists")
    func defaultAndPersistence() throws {
        let suite = "AppLocalBehaviorSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppLocalBehaviorSettings(defaults: defaults)
        #expect(settings.subagentRecentFinishedRetentionMinutes == 5)
        for minutes in 0...5 {
            settings.subagentRecentFinishedRetentionMinutes = minutes
            #expect(AppLocalBehaviorSettings(defaults: defaults).subagentRecentFinishedRetentionMinutes == minutes)
        }
    }

    @Test("out-of-range assignments persist their bounded value")
    func boundedRange() throws {
        let suite = "AppLocalBehaviorSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppLocalBehaviorSettings(defaults: defaults)
        settings.subagentRecentFinishedRetentionMinutes = 3
        settings.subagentRecentFinishedRetentionMinutes = 99
        #expect(settings.subagentRecentFinishedRetentionMinutes == 5)
        #expect(AppLocalBehaviorSettings(defaults: defaults).subagentRecentFinishedRetentionMinutes == 5)
        settings.subagentRecentFinishedRetentionMinutes = -1
        #expect(settings.subagentRecentFinishedRetentionMinutes == 0)
        #expect(AppLocalBehaviorSettings(defaults: defaults).subagentRecentFinishedRetentionMinutes == 0)
        defaults.set(99, forKey: AppLocalBehaviorSettings.subagentRecentFinishedRetentionKey)
        #expect(AppLocalBehaviorSettings(defaults: defaults).subagentRecentFinishedRetentionMinutes == 5)
        defaults.set("invalid", forKey: AppLocalBehaviorSettings.subagentRecentFinishedRetentionKey)
        #expect(AppLocalBehaviorSettings(defaults: defaults).subagentRecentFinishedRetentionMinutes == 5)
    }
}

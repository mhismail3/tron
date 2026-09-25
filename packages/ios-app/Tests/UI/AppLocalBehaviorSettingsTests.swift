import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("App-local behavior settings")
struct AppLocalBehaviorSettingsTests {

    @Test("dashboard chat count bounds assignments and corrupt saved preferences")
    func dashboardBounds() throws {
        let suite = "AppLocalBehaviorSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppLocalBehaviorSettings(defaults: defaults)
        for (input, expected) in [(Int.min, 1), (0, 1), (101, 100), (Int.max, 100)] {
            settings.dashboardChatsPerProject = input
            #expect(settings.dashboardChatsPerProject == expected)
            #expect(AppLocalBehaviorSettings(defaults: defaults).dashboardChatsPerProject == expected)
            defaults.set(input, forKey: AppLocalBehaviorSettings.dashboardChatsPerProjectKey)
            #expect(AppLocalBehaviorSettings(defaults: defaults).dashboardChatsPerProject == expected)
        }
        defaults.set("invalid", forKey: AppLocalBehaviorSettings.dashboardChatsPerProjectKey)
        #expect(AppLocalBehaviorSettings(defaults: defaults).dashboardChatsPerProject == 10)
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

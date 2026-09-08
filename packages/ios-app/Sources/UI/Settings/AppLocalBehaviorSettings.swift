import Foundation

/// Preferences owned by the iOS app presentation, never by a Gateway session.
@MainActor
@Observable
final class AppLocalBehaviorSettings {
    static let shared = AppLocalBehaviorSettings(defaults: .standard)

    static let subagentRecentFinishedRetentionKey = "subagentRecentFinishedRetentionMinutes.v1"
    static let defaultSubagentRecentFinishedRetentionMinutes = 5
    static let subagentRecentFinishedRetentionRange = 0...5

    private let defaults: UserDefaults

    var subagentRecentFinishedRetentionMinutes: Int {
        didSet {
            let bounded = Self.subagentRecentFinishedRetentionRange.clamp(subagentRecentFinishedRetentionMinutes)
            if bounded != subagentRecentFinishedRetentionMinutes {
                subagentRecentFinishedRetentionMinutes = bounded
            }
            defaults.set(bounded, forKey: Self.subagentRecentFinishedRetentionKey)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.subagentRecentFinishedRetentionKey) as? Int
        subagentRecentFinishedRetentionMinutes = Self.subagentRecentFinishedRetentionRange.clamp(
            stored ?? Self.defaultSubagentRecentFinishedRetentionMinutes
        )
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}

import Foundation
import Observation

@MainActor
@Observable
final class SwiftAppExperiment {
    static let shared = SwiftAppExperiment(defaults: .standard)
    nonisolated static let defaultsKey = "tron.experimental.swiftApps"

    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let launchValue = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[Self.defaultsKey] {
            let enabled = (launchValue as? NSString)?.boolValue ?? (launchValue as? Bool ?? false)
            defaults.set(enabled, forKey: Self.defaultsKey)
            isEnabled = enabled
        } else {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
    }

    static let devicePreferenceKey = "experimental.swiftApps"

    enum DevicePreferenceOutcome: Equatable { case applied, conflict(current: Bool) }

    func compareAndSetDevicePreference(expected: Bool, to value: Bool) -> DevicePreferenceOutcome {
        guard isEnabled == expected else { return .conflict(current: isEnabled) }
        isEnabled = value
        return .applied
    }

    func canRun(fileNamed name: String) -> Bool {
        isEnabled && name.lowercased().hasSuffix(".swift")
    }
}

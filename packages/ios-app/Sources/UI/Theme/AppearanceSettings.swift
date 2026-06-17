import SwiftUI

/// Tri-state appearance mode: Light, Dark, or Auto (follow system)
enum AppearanceMode: String, CaseIterable, Sendable {
    case light
    case dark
    case auto

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }

    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .auto: return "Auto"
        }
    }

    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .auto: return "circle.lefthalf.filled"
        }
    }
}

/// Observable appearance settings following the FontSettings singleton pattern
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        }
    }

    var thinkingIndicatorStyle: ThinkingIndicatorStyle {
        didSet {
            UserDefaults.standard.set(thinkingIndicatorStyle.rawValue, forKey: "thinkingIndicatorStyle")
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "appearanceMode"),
           let parsed = AppearanceMode(rawValue: saved) {
            self.mode = parsed
        } else {
            self.mode = .dark
        }

        if let saved = UserDefaults.standard.string(forKey: "thinkingIndicatorStyle"),
           let parsed = ThinkingIndicatorStyle(rawValue: saved) {
            self.thinkingIndicatorStyle = parsed
        } else {
            self.thinkingIndicatorStyle = .neuralSpark
        }
    }
}

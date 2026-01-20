import SwiftUI

/// Observable font settings that trigger real-time font updates across the app
@MainActor
@Observable
final class FontSettings {
    /// Shared singleton instance
    static let shared = FontSettings()

    /// CASL axis value (0 = Linear, 1 = Casual)
    /// Default is 0.5 for a balanced semi-casual look
    var casualAxis: Double {
        didSet {
            UserDefaults.standard.set(casualAxis, forKey: "fontCasualAxis")
        }
    }

    private init() {
        // Load saved value or default to 0.5
        let saved = UserDefaults.standard.double(forKey: "fontCasualAxis")
        self.casualAxis = saved == 0 && !UserDefaults.standard.bool(forKey: "fontCasualAxisSet")
            ? 0.5
            : saved
        // Mark that we've set a value (to distinguish 0.0 from "never set")
        UserDefaults.standard.set(true, forKey: "fontCasualAxisSet")
    }
}

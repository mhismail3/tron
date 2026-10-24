import SwiftUI

/// App identity only. Success, warnings, errors and resource identities stay semantic.
enum ThemeColor: String, CaseIterable, Identifiable, Sendable {
    case emerald, burgundy, oliveGold
    var id: String { rawValue }
    var label: String {
        switch self { case .emerald: "Emerald"; case .burgundy: "Deep Burgundy"; case .oliveGold: "Olive Gold" }
    }
    /// AA ink on the neutral sheet and on low-opacity containers/pills derived
    /// from this same ink. Dark mode lifts the hue rather than using dark pigment.
    var lightHex: String {
        switch self { case .emerald: "#065F46"; case .burgundy: "#57152F"; case .oliveGold: "#514B10" }
    }
    var darkHex: String {
        switch self { case .emerald: "#6EE7B7"; case .burgundy: "#DE7595"; case .oliveGold: "#D9CB75" }
    }
    var ink: Color { Color(lightHex: lightHex, darkHex: darkHex) }

    /// Burgundy needs a dark wine pigment in glass, not the lifted foreground
    /// ink: using readable ink as the tint makes containers dusty pink.
    var surfaceTint: Color {
        self == .burgundy ? Color(lightHex: lightHex, darkHex: "#5B1735") : ink
    }
}

extension Color {
    /// Reading the observable owner here registers the consuming SwiftUI body;
    /// changing identity never recreates the chat, navigation stack or composer.
    @MainActor static var tronPrimary: Color { AppearanceSettings.shared.themeColor.ink }
    @MainActor static var tronPrimarySurface: Color { AppearanceSettings.shared.themeColor.surfaceTint }
}

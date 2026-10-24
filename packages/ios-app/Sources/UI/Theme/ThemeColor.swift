import SwiftUI

/// App identity only. Success, warnings, errors and resource identities stay semantic.
enum ThemeColor: String, CaseIterable, Identifiable, Sendable {
    case emerald, burgundy, oliveGold
    var id: String { rawValue }
    var label: String {
        switch self { case .emerald: "Emerald"; case .burgundy: "Deep Burgundy"; case .oliveGold: "Olive Gold" }
    }
    /// Light ink targets small-text AA. Dark Burgundy deliberately uses deeper
    /// wine-red ink with a 3:1 floor and an explicit small-text AA exception.
    var lightHex: String {
        switch self { case .emerald: "#065F46"; case .burgundy: "#57152F"; case .oliveGold: "#514B10" }
    }
    var darkHex: String {
        switch self { case .emerald: "#6EE7B7"; case .burgundy: "#C34356"; case .oliveGold: "#D9CB75" }
    }
    var ink: Color { Color(lightHex: lightHex, darkHex: darkHex) }

    /// Burgundy glass uses a deeper wine pigment independent of foreground ink.
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

enum ThemeColor: String, CaseIterable, Identifiable, Sendable {
    case emerald, burgundy, oliveGold
    var id: String { rawValue }
    var label: String {
        switch self { case .emerald: "Emerald"; case .burgundy: "Deep Burgundy"; case .oliveGold: "Olive Gold" }
    }
    var lightHex: String {
        switch self { case .emerald: "#065F46"; case .burgundy: "#57152F"; case .oliveGold: "#514B10" }
    }
    var darkHex: String {
        switch self { case .emerald: "#6EE7B7"; case .burgundy: "#B6478C"; case .oliveGold: "#D9CB75" }
    }

    var appIconName: String {
        switch self { case .emerald: "AppIcon"; case .burgundy: "AppIconBurgundy"; case .oliveGold: "AppIconOliveGold" }
    }
}

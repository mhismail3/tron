import SwiftUI
import TronMobileCore

struct ResourceDistributionTag: View {
    let distribution: ResourceDistribution?
    var scope: CommandInfo.ResourceScope?
    let accent: Color

    static func title(for distribution: ResourceDistribution?, scope: CommandInfo.ResourceScope? = nil) -> String? {
        guard let distribution else { return nil }
        switch distribution {
        case .external: return "External"
        case .module: return "Module"
        case .local: return scope == .project ? nil : "Global"
        }
    }

    var body: some View {
        if let title = Self.title(for: distribution, scope: scope) {
            ResourceTagLabel(title: title, accent: accent)
        }
    }
}

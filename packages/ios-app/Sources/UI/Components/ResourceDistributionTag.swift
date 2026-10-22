import SwiftUI
import TronMobileCore

/// The one distribution tag for a resource row. The Gateway derives
/// `distribution` from Pi's sourceInfo; Pi built-ins carry none, so those rows
/// show no tag. A user-authored (`local`) file outside the project is Global
/// (the agent directory's skills, prompts, extensions and agents); a project's
/// own file shows only the Project scope badge beside it.
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

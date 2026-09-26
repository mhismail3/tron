import SwiftUI

/// The one distribution tag for a resource row. The Gateway derives
/// `distribution` from Pi's sourceInfo; Pi built-ins carry none, so those rows
/// show no tag. It sits beside the existing User/Project scope badge, which
/// keeps reporting Pi's own origin and scope.
struct ResourceDistributionTag: View {
    let distribution: ResourceDistribution?
    let accent: Color

    static func title(for distribution: ResourceDistribution?) -> String? {
        guard let distribution else { return nil }
        switch distribution {
        case .external: return "External"
        case .module: return "Module"
        case .local: return "Local"
        }
    }

    var body: some View {
        if let title = Self.title(for: distribution) {
            ResourceTagLabel(title: title, accent: accent)
        }
    }
}

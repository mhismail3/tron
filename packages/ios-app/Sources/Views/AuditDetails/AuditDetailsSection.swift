import SwiftUI

@available(iOS 26.0, *)
extension AuditDetailsView {
    enum AuditSection: String, CaseIterable {
        case overview = "Overview"
        case substrate = "Substrate"
        case capabilities = "Capabilities"
        case plugins = "Plugins"
        case workers = "Workers"
        case bindings = "Bindings"
        case policies = "Policies"
        case audit = "Audit"
        case traces = "Traces"
        case primer = "Primer"
        case programRuns = "Program Runs"

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.bottom.50percent"
            case .substrate: "square.stack.3d.up"
            case .capabilities: "sparkle.magnifyingglass"
            case .plugins: "puzzlepiece.extension"
            case .workers: "server.rack"
            case .bindings: "point.3.connected.trianglepath.dotted"
            case .policies: "checkmark.shield"
            case .audit: "list.bullet.rectangle"
            case .traces: "waterfall"
            case .primer: "text.book.closed"
            case .programRuns: "curlybraces.square"
            }
        }

        var isAdvanced: Bool {
            switch self {
            case .overview, .substrate, .capabilities, .programRuns:
                false
            case .plugins, .workers, .bindings, .policies, .audit, .traces, .primer:
                true
            }
        }
    }
}

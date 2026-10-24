import Foundation
import TronMobileCore

extension HomeToolDetailPresentation {
    /// Canonical check-ins carry a nested receipt, not a generic object to browse.
    /// Running/rejected calls may only have arguments; never infer a saved receipt.
    static func checkin(_ call: Call) -> HomeToolDetailPresentation? {
        let receipt = call.details?["checkin"]?.objectValue
        guard receipt != nil || call.running || call.error else { return nil }
        let fields = receipt ?? call.arguments
        func text(_ key: String) -> String? {
            fields[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        let summary = text("summary") ?? text("message") ?? text("step") ?? "Check-in"
        let attention = text("attention")
        let attentionTitle: String? = attention.map {
            switch $0 {
            case "none": "None"
            case "requested": "Requested"
            case "rate-limited": "Rate limited"
            case "pending": "Pending"
            default: $0
            }
        }
        var sections: [Section] = []
        if let failure = call.failure { sections.append(failure) }
        var attentionRows: [Row] = []
        if let attentionTitle {
            attentionRows.append(Row(icon: "bell", title: "Attention", value: attentionTitle))
        }
        if let needsAttention = fields["needsAttention"]?.boolValue {
            attentionRows.append(Row(icon: "hand.raised", title: "Needs attention", value: needsAttention ? "Yes" : "No"))
        }
        if let blocker = text("blocker") {
            attentionRows.append(Row(icon: "exclamationmark.circle", title: "Blocker", value: blocker))
        }
        if !attentionRows.isEmpty { sections.append(.rows(title: "Attention", detail: nil, rows: attentionRows)) }
        var progress: [Row] = []
        // Summary/message variants still keep the explicit step, when supplied.
        if let step = text("step"), step != summary {
            progress.append(Row(icon: "flag", title: "Step", value: step))
        }
        for (key, title, icon) in [("done", "Done", "checkmark.circle"), ("next", "Next", "arrow.right"),
                                   ("progress", "Progress", "chart.bar"), ("milestone", "Milestone", "flag")] {
            if let value = text(key) { progress.append(Row(icon: icon, title: title, value: value)) }
        }
        if !progress.isEmpty { sections.append(.rows(title: "Progress", detail: nil, rows: progress)) }
        var details: [Row] = []
        if let at = text("at") {
            let timestamp = GatewayTimestamp.parse(at)?.formatted(date: .abbreviated, time: .standard) ?? at
            details.append(Row(icon: "clock", title: "Timestamp", value: timestamp))
        }
        if let refs = fields["refs"]?.objectValue {
            for (key, title, icon) in [("branch", "Branch", "arrow.triangle.branch"), ("commit", "Commit", "point.topleft.down.to.point.bottomright.curvepath"), ("issue", "Issue", "number")] {
                if let value = refs[key]?.stringValue, !value.isEmpty {
                    details.append(Row(icon: icon, title: title, value: value))
                }
            }
        }
        if !details.isEmpty { sections.append(.rows(title: "Details", detail: nil, rows: details)) }
        let needsAttention = fields["needsAttention"]?.boolValue == true
        let header: Header
        if call.running {
            header = runningHeader(icon: "text.bubble", title: summary, subtitle: nil)
        } else {
            header = Header(icon: "text.bubble", title: summary, subtitle: nil,
                            pill: call.error ? "Failed" : needsAttention ? "Needs attention" : "Saved",
                            tone: call.error ? .failure : needsAttention ? .pending : .neutral)
        }
        return Self(header: header, sections: sections)
    }
}

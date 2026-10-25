import Foundation
import TronMobileCore

extension HomeToolDetailPresentation {
    /// Report content belongs to the accepted invocation. Its result only carries
    /// an opaque transcript receipt; keep that receipt in Technical details.
    static func report(_ call: Call) -> HomeToolDetailPresentation? {
        guard call.string("outcome") != nil || call.string("text") != nil || call.running || call.error else { return nil }
        let outcome = call.string("outcome")
        let status: String
        let tone: Tone
        switch outcome {
        case "final": (status, tone) = ("Done", .success)
        case "progress": (status, tone) = ("Progress", .neutral)
        case "needs-input": (status, tone) = ("Needs input", .pending)
        case "blocked": (status, tone) = ("Blocked", .pending)
        default: (status, tone) = ("Reported", .neutral)
        }
        var sections: [Section] = []
        if let failure = call.failure { sections.append(failure) }
        if let text = call.string("text") {
            sections.append(.text(id: "report", title: "Summary", text: text))
        }
        if let evidence = call.arguments["evidence"]?.arrayValue?.compactMap(\.stringValue), !evidence.isEmpty {
            let markdown = evidence.enumerated().map { index, item in
                "\(index + 1). " + item.replacingOccurrences(of: "\n", with: "\n   ")
            }.joined(separator: "\n\n")
            sections.append(.text(id: "evidence", title: "Acceptance evidence", text: markdown))
        }
        let header = call.running
            ? runningHeader(icon: "doc.text.fill", title: "Report result", subtitle: nil)
            : Header(icon: "doc.text.fill", title: "Report result", subtitle: nil,
                     pill: call.error ? "Failed" : status, tone: call.error ? .failure : tone)
        return Self(header: header, sections: sections)
    }
}

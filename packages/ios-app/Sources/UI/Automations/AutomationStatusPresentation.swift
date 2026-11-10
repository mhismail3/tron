import SwiftUI
import TronMobileCore

enum AutomationStatusPresentation {
    @MainActor static func color(_ activation: AutomationActivation, run: AutomationRunState? = nil) -> Color {
        if run == .outcomeUnknown || run == .failed || activation == .blocked { return .tronError }
        if run == .succeeded { return .tronSuccess }
        if run?.isInFlight == true { return .tronPrimary }
        switch activation {
        case .enabled: return .tronPrimary
        case .paused, .draft, .completed, .expired: return .tronSlate
        case .blocked: return .tronError
        }
    }

    static func icon(_ run: AutomationRunState) -> String {
        switch run {
        case .outcomeUnknown: "exclamationmark.triangle.fill"
        case .running: "play.circle.fill"
        case .queued, .waiting, .admitting: "hourglass.circle.fill"
        case .cancelling: "xmark.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "slash.circle"
        case .skipped: "arrow.right.circle"
        }
    }
}

enum AutomationDateFormatting {
    private static let style = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func date(_ value: String?) -> String {
        guard let value, let date = GatewayTimestamp.parse(value) else { return value ?? "—" }
        return date.formatted(style)
    }
}

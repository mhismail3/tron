import SwiftUI
import TronMobileCore

/// Automations follow the user's primary theme; only attention and failure
/// read in the error colour, a success in the success colour, and an idle
/// lifecycle in slate.
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
    /// Format styles are values, so every row reuses one instead of building a
    /// formatter per call.
    private static let style = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func date(_ value: String?) -> String {
        guard let value, let date = GatewayTimestamp.parse(value) else { return value ?? "—" }
        return date.formatted(style)
    }
}

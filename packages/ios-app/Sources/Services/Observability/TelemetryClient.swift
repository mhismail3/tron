import Foundation

/// Closed enum of events the app emits to PostHog (and mirrors to
/// Sentry breadcrumbs for debugging). The closed-enum shape is
/// deliberate: every call site spells out the event type, so the
/// Privacy Settings page can render an up-to-date list by iterating
/// over `TelemetryEvent.allCasesForDocumentation`.
///
/// See plan §F "Telemetry (PostHog, opt-in)" for the full schema.
enum TelemetryEvent {
    case appInstalled
    case pairingCompleted
    case providerAuthenticated(provider: String)
    case sessionStarted
    case sessionCompleted(durationSeconds: Double, messageCount: Int)
    case toolInvoked(toolName: String)
    case updateCheckCompleted(current: String, latest: String?, action: String)
    case feedbackSubmitted
    case errorOccurred(component: String, errorClass: String)

    var name: String {
        switch self {
        case .appInstalled: return "app_installed"
        case .pairingCompleted: return "pairing_completed"
        case .providerAuthenticated: return "provider_authenticated"
        case .sessionStarted: return "session_started"
        case .sessionCompleted: return "session_completed"
        case .toolInvoked: return "tool_invoked"
        case .updateCheckCompleted: return "update_check_completed"
        case .feedbackSubmitted: return "feedback_submitted"
        case .errorOccurred: return "error_occurred"
        }
    }

    var properties: [String: Any] {
        switch self {
        case .appInstalled, .pairingCompleted, .sessionStarted, .feedbackSubmitted:
            return [:]
        case .providerAuthenticated(let provider):
            return ["provider": provider]
        case .sessionCompleted(let durationSeconds, let messageCount):
            return [
                "duration_seconds": durationSeconds,
                "message_count": messageCount,
            ]
        case .toolInvoked(let toolName):
            return ["tool_name": toolName]
        case .updateCheckCompleted(let current, let latest, let action):
            var out: [String: Any] = ["current": current, "action": action]
            if let latest = latest { out["latest"] = latest }
            return out
        case .errorOccurred(let component, let errorClass):
            return ["component": component, "error_class": errorClass]
        }
    }

    /// Documentation list used by `PrivacySettingsPage` to render the
    /// exact set of events that ship when telemetry is on. Not a
    /// `CaseIterable` because the enum has associated values; every
    /// case here has a dummy value that's only used for its `.name`.
    static var allCasesForDocumentation: [TelemetryEvent] {
        [
            .appInstalled,
            .pairingCompleted,
            .providerAuthenticated(provider: ""),
            .sessionStarted,
            .sessionCompleted(durationSeconds: 0, messageCount: 0),
            .toolInvoked(toolName: ""),
            .updateCheckCompleted(current: "", latest: nil, action: ""),
            .feedbackSubmitted,
            .errorOccurred(component: "", errorClass: ""),
        ]
    }
}

/// Abstract telemetry sink. Production code reads
/// `DependencyContainer.telemetryClient`, which is built via
/// `TelemetryClientFactory.make(enabled:)` from the persisted opt-in and
/// rebuilt in place when the toggle flips (no app restart needed). Until
/// the PostHog SDK is wired in (plan follow-up) every call site still
/// resolves to a `NullTelemetryClient`. Tests inject
/// `InMemoryTelemetryClient` to assert emission.
protocol TelemetryClient: AnyObject {
    var isEnabled: Bool { get }
    func track(_ event: TelemetryEvent)
}

/// No-op implementation. Default production fallback until SDK
/// integration lands. Discarding events here keeps the rest of the
/// app telemetry-call-site-complete — SDK swap becomes a one-line
/// change in `TelemetryClientFactory.make()`.
final class NullTelemetryClient: TelemetryClient {
    var isEnabled: Bool { false }
    func track(_ event: TelemetryEvent) { /* drop */ }
}

/// In-memory client used by tests. Stores events for assertions.
/// Also enforces a rate limiter so real-production drop semantics
/// are exercised in tests.
final class InMemoryTelemetryClient: TelemetryClient {
    private(set) var recordedEvents: [TelemetryEvent] = []
    private let rateLimiter: TokenBucket?
    let isEnabled: Bool

    init(enabled: Bool, rateLimiter: TokenBucket? = nil) {
        self.isEnabled = enabled
        self.rateLimiter = rateLimiter
    }

    func track(_ event: TelemetryEvent) {
        guard isEnabled else { return }
        if let bucket = rateLimiter, !bucket.tryConsume() { return }
        recordedEvents.append(event)
    }
}

/// Factory that the app queries for a live client. The container
/// (`DependencyContainer`) calls this on init using the persisted
/// `@AppStorage("telemetryEnabled")` value AND on every flip of that
/// key (via a `UserDefaults.didChangeNotification` observer), so a
/// toggle in Privacy → Telemetry replaces the live sink mid-session
/// without an app restart. Returns `NullTelemetryClient` when
/// opted-out — that's the contract the rest of the codebase relies on
/// (call sites can `client.track(...)` unconditionally).
///
/// Once the PostHog SDK is wired in, replace the `enabled` branch with
/// the SDK-backed client; the wiring above is already in place.
enum TelemetryClientFactory {
    static func make(enabled: Bool) -> TelemetryClient {
        if enabled {
            // TODO(phase-7-follow-up): swap for PostHog-backed client
            // once `posthog-ios` SwiftPM dependency is added. For now,
            // opt-in still yields a Null client — events drop locally.
            return NullTelemetryClient()
        }
        return NullTelemetryClient()
    }
}

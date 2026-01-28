import Foundation

// MARK: - Scroll Target

/// Represents a scroll target within a session
enum ScrollTarget: Equatable {
    /// Scroll to a specific tool call by ID
    case toolCall(id: String)
    /// Scroll to a specific event by ID
    case event(id: String)
    /// Scroll to bottom (default behavior)
    case bottom
}

// MARK: - Navigation Intent

/// Represents a navigation destination from deep links
enum NavigationIntent: Equatable {
    /// Navigate to a specific session, optionally scrolling to a target
    case session(id: String, scrollTo: ScrollTarget?)
    /// Navigate to settings
    case settings
    /// Navigate to voice notes
    case voiceNotes
}

// MARK: - Deep Link Router

/// Central router for handling deep links from notifications and URLs.
///
/// This router consolidates all deep link handling:
/// - Push notification taps (via AppDelegate)
/// - URL scheme handling (tron:// and tron-mobile://)
///
/// Usage:
/// 1. Call `handle(notificationPayload:)` when notification is tapped
/// 2. Call `handle(url:)` when URL scheme is opened
/// 3. Observe `pendingIntent` for navigation changes
/// 4. Call `consumeIntent()` to get and clear the pending intent
@Observable
@MainActor
final class DeepLinkRouter {
    /// The pending navigation intent to be handled
    var pendingIntent: NavigationIntent?

    // MARK: - Notification Handling

    /// Handle notification payload from AppDelegate
    /// - Parameter notificationPayload: The userInfo dictionary from the notification
    func handle(notificationPayload: [AnyHashable: Any]) {
        guard let sessionId = notificationPayload["sessionId"] as? String else {
            TronLogger.shared.warning("Deep link notification missing sessionId", category: .notification)
            return
        }

        let scrollTarget: ScrollTarget?
        if let toolCallId = notificationPayload["toolCallId"] as? String {
            scrollTarget = .toolCall(id: toolCallId)
        } else if let eventId = notificationPayload["eventId"] as? String {
            scrollTarget = .event(id: eventId)
        } else {
            scrollTarget = nil
        }

        pendingIntent = .session(id: sessionId, scrollTo: scrollTarget)
        TronLogger.shared.info("Deep link intent set: session=\(sessionId), scrollTo=\(String(describing: scrollTarget))", category: .notification)
    }

    // MARK: - URL Scheme Handling

    /// Handle URL scheme (tron:// or tron-mobile://)
    ///
    /// URLs are parsed as: `scheme://host/path?query`
    /// For custom URL schemes, the "host" is typically used as the route type.
    /// Examples:
    /// - `tron://session/sess_123` → host="session", path="/sess_123"
    /// - `tron://settings` → host="settings", path=""
    ///
    /// - Parameter url: The URL to handle
    /// - Returns: true if the URL was handled, false otherwise
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "tron" || url.scheme == "tron-mobile" else {
            return false
        }

        // In custom URL schemes, the host acts as the route type
        // e.g., tron://session/sess_123 has host="session"
        guard let routeType = url.host else {
            return false
        }

        switch routeType {
        case "session":
            return handleSessionURL(url: url)

        case "settings":
            pendingIntent = .settings
            TronLogger.shared.info("Deep link intent set: settings", category: .notification)
            return true

        case "voice-notes":
            pendingIntent = .voiceNotes
            TronLogger.shared.info("Deep link intent set: voiceNotes", category: .notification)
            return true

        default:
            TronLogger.shared.warning("Unknown deep link route: \(routeType)", category: .notification)
            return false
        }
    }

    /// Handle session URL (tron://session/{sessionId}?tool=...&event=...)
    /// The session ID is the first path component after the host.
    private func handleSessionURL(url: URL) -> Bool {
        // Path components include "/" as first element, then the actual path segments
        // e.g., tron://session/sess_123 has path="/sess_123", pathComponents=["/", "sess_123"]
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        guard let sessionId = pathComponents.first, !sessionId.isEmpty else {
            TronLogger.shared.warning("Session deep link missing sessionId", category: .notification)
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        var scrollTarget: ScrollTarget?
        if let toolId = components?.queryItems?.first(where: { $0.name == "tool" })?.value {
            scrollTarget = .toolCall(id: toolId)
        } else if let eventId = components?.queryItems?.first(where: { $0.name == "event" })?.value {
            scrollTarget = .event(id: eventId)
        }

        pendingIntent = .session(id: sessionId, scrollTo: scrollTarget)
        TronLogger.shared.info("Deep link intent set: session=\(sessionId), scrollTo=\(String(describing: scrollTarget))", category: .notification)
        return true
    }

    // MARK: - Intent Consumption

    /// Consume and clear the pending intent.
    /// Use this to get the intent and acknowledge that navigation will be performed.
    /// - Returns: The pending intent, or nil if none
    func consumeIntent() -> NavigationIntent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }
}

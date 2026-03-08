import UIKit

/// Provides haptic feedback for agent events.
///
/// Triggered by event handlers (task complete, error, notification) when
/// haptics are enabled in integration settings.
@MainActor
final class HapticService {
    static let shared = HapticService()

    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        impactGenerator.prepare()
        notificationGenerator.prepare()
    }

    /// Cached settings, updated when integration settings change.
    var cachedSettings = ServerSettings.IntegrationSettings.HapticsSettings.defaults

    /// Trigger haptic feedback for the given event type, respecting settings.
    func trigger(for event: HapticEvent, settings: ServerSettings.IntegrationSettings.HapticsSettings) {
        cachedSettings = settings
        guard settings.enabled else { return }

        switch event {
        case .taskComplete:
            guard settings.onTaskComplete else { return }
            notificationGenerator.notificationOccurred(.success)
        case .error:
            guard settings.onError else { return }
            notificationGenerator.notificationOccurred(.error)
        case .notification:
            guard settings.onNotification else { return }
            impactGenerator.impactOccurred(intensity: 0.5)
        }
    }

    /// Trigger notification haptic using cached settings.
    /// Used from contexts without RPC access (e.g. AppDelegate).
    func triggerNotification() {
        trigger(for: .notification, settings: cachedSettings)
    }
}

/// Haptic event types that can trigger feedback.
enum HapticEvent {
    case taskComplete
    case error
    case notification
}

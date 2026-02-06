import Foundation

/// Coordinates event dispatch by routing plugin events to the appropriate handlers.
/// Delegates to self-dispatching plugins via the EventRegistry's plugin boxes.
@MainActor
final class EventDispatchCoordinator {

    /// Dispatch an event to the appropriate handler on the context.
    /// Looks up the plugin box from EventRegistry and delegates dispatch to it.
    func dispatch(
        type: String,
        transform: @Sendable () -> (any EventResult)?,
        context: EventDispatchTarget
    ) {
        guard let result = transform() else {
            context.logWarning("Failed to transform event: \(type)")
            return
        }

        guard let box = EventRegistry.shared.pluginBox(for: type) else {
            context.logDebug("No plugin registered for event type: \(type)")
            return
        }

        if !box.dispatch(result: result, context: context) {
            context.logDebug("Unhandled plugin event type: \(type)")
        }
    }
}

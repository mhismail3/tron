import ApplicationServices
import CoreGraphics
import Foundation

extension MacOperatorActuator {
    func mutate(
        bundleIdentifier: String,
        observationID: String,
        operation: (MacOperatorObservation) throws -> Void
    ) async throws -> [String: Any] {
        try requireRunning()
        let observation = try currentObservation(
            bundleIdentifier: bundleIdentifier,
            observationID: observationID
        )
        try validateFocus(observation)
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        // INVARIANT: consume the observation before actuation. If the native
        // action succeeds but verification fails, a retry cannot replay the
        // same click or key against stale UI.
        invalidateObservation()
        try operation(observation)
        try await Task.sleep(for: .milliseconds(120))

        do {
            let fresh = try createObservation(bundleIdentifier: bundleIdentifier)
            return [
                "acted": true,
                "freshObservation": fresh,
            ]
        } catch MacOperatorActuatorError.targetNotForeground {
            return [
                "acted": true,
                "verification": "focus_changed",
            ]
        } catch MacOperatorActuatorError.focusedWindowUnavailable {
            return [
                "acted": true,
                "verification": "window_changed",
            ]
        }
    }

    func element(
        reference: String,
        in observation: MacOperatorObservation
    ) throws -> AXUIElement {
        guard let element = observation.elements[reference] else {
            throw MacOperatorActuatorError.elementUnavailable
        }
        return element
    }

    func requireWritableNonSecureElement(_ element: AXUIElement) throws {
        let role = stringValue(element, attribute: kAXRoleAttribute as CFString)
        let subrole = stringValue(element, attribute: kAXSubroleAttribute as CFString)
        guard subrole != kAXSecureTextFieldSubrole as String else {
            throw MacOperatorActuatorError.secureInputRefused
        }
        guard role == kAXTextFieldRole as String
                || role == kAXTextAreaRole as String
                || role == kAXComboBoxRole as String
        else {
            throw MacOperatorActuatorError.actionUnsupported
        }
        guard settable(kAXValueAttribute as CFString, element: element) else {
            throw MacOperatorActuatorError.actionUnsupported
        }
    }

    func supportsAction(_ action: String, element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let values = names as? [String]
        else {
            return false
        }
        return values.contains(action)
    }

    func settable(_ attribute: CFString, element: AXUIElement) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &result) == .success
            && result.boolValue
    }

    static let keyCodes: [MacOperatorKey: CGKeyCode] = [
        .enter: 36,
        .tab: 48,
        .escape: 53,
        .arrowUp: 126,
        .arrowDown: 125,
        .arrowLeft: 123,
        .arrowRight: 124,
        .pageUp: 116,
        .pageDown: 121,
        .home: 115,
        .end: 119,
        .backspace: 51,
        .delete: 117,
        .space: 49,
    ]
}

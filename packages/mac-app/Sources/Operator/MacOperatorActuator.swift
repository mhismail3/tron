import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MacOperatorActuatorError: Error, Equatable, Sendable {
    case emergencyStop
    case accessibilityPermissionRequired
    case screenRecordingPermissionRequired
    case appNotRunning
    case targetNotForeground
    case focusedWindowUnavailable
    case staleObservation
    case staleScreenshot
    case elementUnavailable
    case actionUnsupported
    case secureInputRefused
    case nativeActionFailed
    case screenshotUnavailable
    case responseOversized

    var code: String {
        switch self {
        case .emergencyStop: "emergency_stop_engaged"
        case .accessibilityPermissionRequired: "accessibility_permission_required"
        case .screenRecordingPermissionRequired: "screen_recording_permission_required"
        case .appNotRunning: "target_app_not_running"
        case .targetNotForeground: "target_app_not_foreground"
        case .focusedWindowUnavailable: "focused_window_unavailable"
        case .staleObservation: "stale_observation"
        case .staleScreenshot: "stale_screenshot"
        case .elementUnavailable: "element_unavailable"
        case .actionUnsupported: "action_unsupported"
        case .secureInputRefused: "secure_input_refused"
        case .nativeActionFailed: "native_action_failed"
        case .screenshotUnavailable: "screenshot_unavailable"
        case .responseOversized: "response_oversized"
        }
    }
}

/// Mechanical macOS actuator. This owner validates foreground/window identity,
/// holds only the latest observation, and executes one closed action at a time.
/// It never interprets the user's goal or chooses an action.
actor MacOperatorActuator {
    let safety: MacOperatorSafetyState
    var sequence: UInt64 = 0
    var latestObservation: MacOperatorObservation?
    var latestScreenshotID: String?
    private var isExecuting = false

    init(safety: MacOperatorSafetyState) {
        self.safety = safety
    }

    func responseData(for request: MacOperatorRequest) async -> Data {
        do {
            return MacOperatorProtocol.successData(
                requestID: request.requestID,
                result: try await execute(request)
            )
        } catch let error as MacOperatorActuatorError {
            return MacOperatorProtocol.failureData(
                requestID: request.requestID,
                code: error.code
            )
        } catch is CancellationError {
            return MacOperatorProtocol.failureData(
                requestID: request.requestID,
                code: "native_action_cancelled"
            )
        } catch {
            return MacOperatorProtocol.failureData(
                requestID: request.requestID,
                code: "native_action_failed"
            )
        }
    }

    private func execute(_ request: MacOperatorRequest) async throws -> [String: Any] {
        guard !isExecuting else {
            throw MacOperatorActuatorError.nativeActionFailed
        }
        isExecuting = true
        defer { isExecuting = false }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        switch request.action {
        case .status:
            let snapshot = safety.snapshot()
            return [
                "emergencyStop": snapshot.isStopped,
                "accessibility": AXIsProcessTrusted(),
                "screenRecording": CGPreflightScreenCaptureAccess(),
            ]
        case .applications:
            try requireRunning()
            return applicationsResult()
        case .observe(let bundleIdentifier):
            try requireRunning()
            return try createObservation(bundleIdentifier: bundleIdentifier)
        case .screenshot(let bundleIdentifier, let observationID):
            try requireRunning()
            return try await screenshot(
                bundleIdentifier: bundleIdentifier,
                observationID: observationID
            )
        case .press(let bundleIdentifier, let observationID, let elementReference):
            return try await mutate(
                bundleIdentifier: bundleIdentifier,
                observationID: observationID
            ) { observation in
                let element = try self.element(
                    reference: elementReference,
                    in: observation
                )
                guard self.supportsAction(kAXPressAction, element: element) else {
                    throw MacOperatorActuatorError.actionUnsupported
                }
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                    throw MacOperatorActuatorError.nativeActionFailed
                }
            }
        case .setValue(
            let bundleIdentifier,
            let observationID,
            let elementReference,
            let text
        ):
            return try await mutate(
                bundleIdentifier: bundleIdentifier,
                observationID: observationID
            ) { observation in
                let element = try self.element(
                    reference: elementReference,
                    in: observation
                )
                try self.requireWritableNonSecureElement(element)
                guard AXUIElementSetAttributeValue(
                    element,
                    kAXValueAttribute as CFString,
                    text as CFTypeRef
                ) == .success
                else {
                    throw MacOperatorActuatorError.nativeActionFailed
                }
            }
        case .key(let bundleIdentifier, let observationID, let key):
            return try await mutate(
                bundleIdentifier: bundleIdentifier,
                observationID: observationID
            ) { _ in
                guard let keyCode = Self.keyCodes[key],
                      let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
                else {
                    throw MacOperatorActuatorError.actionUnsupported
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        case .scroll(let bundleIdentifier, let observationID, let deltaX, let deltaY):
            return try await mutate(
                bundleIdentifier: bundleIdentifier,
                observationID: observationID
            ) { _ in
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(deltaY),
                    wheel2: Int32(deltaX),
                    wheel3: 0
                ) else {
                    throw MacOperatorActuatorError.nativeActionFailed
                }
                event.post(tap: .cghidEventTap)
            }
        case .coordinateClick(
            let bundleIdentifier,
            let observationID,
            let screenshotID,
            let normalizedX,
            let normalizedY
        ):
            guard latestScreenshotID == screenshotID else {
                throw MacOperatorActuatorError.staleScreenshot
            }
            return try await mutate(
                bundleIdentifier: bundleIdentifier,
                observationID: observationID
            ) { observation in
                let point = CGPoint(
                    x: observation.windowBounds.minX
                        + observation.windowBounds.width * normalizedX,
                    y: observation.windowBounds.minY
                        + observation.windowBounds.height * normalizedY
                )
                guard observation.windowBounds.contains(point),
                      let down = CGEvent(
                          mouseEventSource: nil,
                          mouseType: .leftMouseDown,
                          mouseCursorPosition: point,
                          mouseButton: .left
                      ),
                      let up = CGEvent(
                          mouseEventSource: nil,
                          mouseType: .leftMouseUp,
                          mouseCursorPosition: point,
                          mouseButton: .left
                      )
                else {
                    throw MacOperatorActuatorError.nativeActionFailed
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}

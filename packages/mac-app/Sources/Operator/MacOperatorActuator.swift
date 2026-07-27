import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    private struct WindowRecord {
        let number: CGWindowID
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let applicationName: String
        let title: String
        let bounds: CGRect
    }

    private struct Observation {
        let identifier: String
        let safetyGeneration: UInt64
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let windowNumber: CGWindowID
        let windowBounds: CGRect
        let focusedWindow: AXUIElement
        let elements: [String: AXUIElement]
    }

    private let safety: MacOperatorSafetyState
    private var sequence: UInt64 = 0
    private var latestObservation: Observation?
    private var latestScreenshotID: String?
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

    private func requireRunning() throws {
        guard !safety.snapshot().isStopped else {
            invalidateObservation()
            throw MacOperatorActuatorError.emergencyStop
        }
    }

    private func applicationsResult() -> [String: Any] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var seen = Set<String>()
        let applications = onScreenWindows().compactMap { window -> [String: Any]? in
            guard seen.insert(window.bundleIdentifier).inserted else { return nil }
            return [
                "bundleId": window.bundleIdentifier,
                "name": window.applicationName,
                "frontmost": window.bundleIdentifier == frontmost,
            ]
        }
        .prefix(32)
        return ["applications": Array(applications)]
    }

    private func createObservation(bundleIdentifier: String) throws -> [String: Any] {
        guard AXIsProcessTrusted() else {
            throw MacOperatorActuatorError.accessibilityPermissionRequired
        }
        let safetySnapshot = safety.snapshot()
        guard !safetySnapshot.isStopped else {
            invalidateObservation()
            throw MacOperatorActuatorError.emergencyStop
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier == bundleIdentifier
        else {
            invalidateObservation()
            throw MacOperatorActuatorError.targetNotForeground
        }

        let (focusedWindow, windowRecord) = try focusedWindowRecord(
            processIdentifier: frontmostApplication.processIdentifier
        )

        sequence &+= 1
        let observationID = "mac-observation-\(sequence)"
        var elements: [String: AXUIElement] = [:]
        var summaries: [[String: Any]] = []
        var visited = Set<CFHashCode>()
        collectElements(
            focusedWindow,
            depth: 0,
            elements: &elements,
            summaries: &summaries,
            visited: &visited
        )
        let observation = Observation(
            identifier: observationID,
            safetyGeneration: safetySnapshot.generation,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: windowRecord.processIdentifier,
            windowNumber: windowRecord.number,
            windowBounds: windowRecord.bounds,
            focusedWindow: focusedWindow,
            elements: elements
        )
        latestObservation = observation
        latestScreenshotID = nil
        return observationResult(
            observation,
            applicationName: windowRecord.applicationName,
            windowTitle: windowRecord.title,
            elementSummaries: summaries
        )
    }

    private func mutate(
        bundleIdentifier: String,
        observationID: String,
        operation: (Observation) throws -> Void
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

    private func screenshot(
        bundleIdentifier: String,
        observationID: String
    ) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw MacOperatorActuatorError.screenRecordingPermissionRequired
        }
        let observation = try currentObservation(
            bundleIdentifier: bundleIdentifier,
            observationID: observationID
        )
        try validateFocus(observation)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw MacOperatorActuatorError.screenshotUnavailable
        }
        guard !Task.isCancelled,
              safety.snapshot().generation == observation.safetyGeneration,
              let window = content.windows.first(where: {
                  $0.windowID == observation.windowNumber
              })
        else {
            throw MacOperatorActuatorError.staleObservation
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = min(max(Int(window.frame.width * 2), 1), 2_400)
        configuration.height = min(max(Int(window.frame.height * 2), 1), 2_400)
        configuration.showsCursor = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw MacOperatorActuatorError.screenshotUnavailable
        }
        guard !Task.isCancelled,
              safety.snapshot().generation == observation.safetyGeneration
        else {
            throw MacOperatorActuatorError.staleObservation
        }
        let encoded = try encodeJPEG(image)
        sequence &+= 1
        let screenshotID = "mac-screenshot-\(sequence)"
        latestScreenshotID = screenshotID
        return [
            "screenshotId": screenshotID,
            "mediaType": "image/jpeg",
            "width": image.width,
            "height": image.height,
            "dataBase64": encoded.base64EncodedString(),
        ]
    }

    private func currentObservation(
        bundleIdentifier: String,
        observationID: String
    ) throws -> Observation {
        let safetySnapshot = safety.snapshot()
        guard let observation = latestObservation,
              observation.identifier == observationID,
              observation.bundleIdentifier == bundleIdentifier,
              observation.safetyGeneration == safetySnapshot.generation,
              !safetySnapshot.isStopped
        else {
            throw MacOperatorActuatorError.staleObservation
        }
        return observation
    }

    private func validateFocus(_ observation: Observation) throws {
        let safetySnapshot = safety.snapshot()
        guard !safetySnapshot.isStopped,
              safetySnapshot.generation == observation.safetyGeneration
        else {
            invalidateObservation()
            throw MacOperatorActuatorError.emergencyStop
        }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier == observation.bundleIdentifier,
              frontmostApplication.processIdentifier == observation.processIdentifier
        else {
            invalidateObservation()
            throw MacOperatorActuatorError.targetNotForeground
        }
        let (focusedWindow, windowRecord) = try focusedWindowRecord(
            processIdentifier: frontmostApplication.processIdentifier
        )
        guard Self.matchesFocusedWindow(
            observedWindow: observation.focusedWindow,
            observedWindowNumber: observation.windowNumber,
            observedProcessIdentifier: observation.processIdentifier,
            focusedWindow: focusedWindow,
            focusedWindowNumber: windowRecord.number,
            focusedProcessIdentifier: windowRecord.processIdentifier
        ) else {
            invalidateObservation()
            throw MacOperatorActuatorError.focusedWindowUnavailable
        }
    }

    /// WindowServer presence alone is insufficient: switching between two
    /// windows in the same app leaves both visible. Match the current AX focus
    /// object and its resolved WindowServer identity before any actuation.
    static func matchesFocusedWindow(
        observedWindow: AXUIElement,
        observedWindowNumber: CGWindowID,
        observedProcessIdentifier: pid_t,
        focusedWindow: AXUIElement,
        focusedWindowNumber: CGWindowID,
        focusedProcessIdentifier: pid_t
    ) -> Bool {
        observedProcessIdentifier == focusedProcessIdentifier
            && observedWindowNumber == focusedWindowNumber
            && CFEqual(observedWindow, focusedWindow)
    }

    private func focusedWindowRecord(
        processIdentifier: pid_t
    ) throws -> (AXUIElement, WindowRecord) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 2)
        guard let rawFocusedWindow = axValue(
            application,
            attribute: kAXFocusedWindowAttribute as CFString
        ),
            CFGetTypeID(rawFocusedWindow) == AXUIElementGetTypeID()
        else {
            invalidateObservation()
            throw MacOperatorActuatorError.focusedWindowUnavailable
        }
        let focusedWindow = unsafeDowncast(rawFocusedWindow, to: AXUIElement.self)
        guard let focusedBounds = elementBounds(focusedWindow),
              let windowRecord = onScreenWindows()
              .filter({ $0.processIdentifier == processIdentifier })
              .min(by: {
                  boundsDistance($0.bounds, focusedBounds)
                      < boundsDistance($1.bounds, focusedBounds)
              })
        else {
            invalidateObservation()
            throw MacOperatorActuatorError.focusedWindowUnavailable
        }
        return (focusedWindow, windowRecord)
    }

    private func element(reference: String, in observation: Observation) throws -> AXUIElement {
        guard let element = observation.elements[reference] else {
            throw MacOperatorActuatorError.elementUnavailable
        }
        return element
    }

    private func requireWritableNonSecureElement(_ element: AXUIElement) throws {
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

    private func supportsAction(_ action: String, element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let values = names as? [String]
        else {
            return false
        }
        return values.contains(action)
    }

    private func settable(_ attribute: CFString, element: AXUIElement) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &result) == .success
            && result.boolValue
    }

    private func collectElements(
        _ element: AXUIElement,
        depth: Int,
        elements: inout [String: AXUIElement],
        summaries: inout [[String: Any]],
        visited: inout Set<CFHashCode>
    ) {
        guard depth <= 10, summaries.count < 256 else { return }
        let hash = CFHash(element)
        guard visited.insert(hash).inserted else { return }

        let role = stringValue(element, attribute: kAXRoleAttribute as CFString)
            ?? "AXUnknown"
        let subrole = stringValue(element, attribute: kAXSubroleAttribute as CFString)
        let isSecure = subrole == kAXSecureTextFieldSubrole as String
        let reference = "element-\(summaries.count + 1)"
        elements[reference] = element

        var summary: [String: Any] = [
            "ref": reference,
            "role": MacOperatorProtocol.sanitize(role, maximumCharacters: 80),
        ]
        if let label = redactedLabel(element, role: role, isSecure: isSecure) {
            summary["label"] = label
        }
        if let enabled = boolValue(element, attribute: kAXEnabledAttribute as CFString) {
            summary["enabled"] = enabled
        }
        let actions = allowedActions(element)
        if !actions.isEmpty {
            summary["actions"] = actions
        }
        if let bounds = elementBounds(element) {
            summary["bounds"] = rectangleDictionary(bounds)
        }
        if isSecure {
            summary["secure"] = true
        }
        summaries.append(summary)
        guard !isSecure,
              let children = axValue(
                  element,
                  attribute: kAXChildrenAttribute as CFString
              ) as? [AXUIElement]
        else {
            return
        }
        for child in children.prefix(64) {
            collectElements(
                child,
                depth: depth + 1,
                elements: &elements,
                summaries: &summaries,
                visited: &visited
            )
            if summaries.count >= 256 { break }
        }
    }

    private func redactedLabel(
        _ element: AXUIElement,
        role: String,
        isSecure: Bool
    ) -> String? {
        guard !isSecure else { return nil }
        for attribute in [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
        ] {
            if let value = stringValue(element, attribute: attribute),
               !value.isEmpty {
                return MacOperatorProtocol.sanitize(value, maximumCharacters: 300)
            }
        }
        // Values are exposed only for non-editable static text. Text fields,
        // areas, combo boxes, and controls never return their contents.
        if role == kAXStaticTextRole as String,
           let value = stringValue(element, attribute: kAXValueAttribute as CFString),
           !value.isEmpty {
            return MacOperatorProtocol.sanitize(value, maximumCharacters: 300)
        }
        return nil
    }

    private func allowedActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let values = names as? [String]
        else {
            return []
        }
        let allowed = Set([
            kAXPressAction as String,
            kAXConfirmAction as String,
            kAXCancelAction as String,
        ])
        return values.filter(allowed.contains).sorted()
    }

    private func observationResult(
        _ observation: Observation,
        applicationName: String,
        windowTitle: String,
        elementSummaries: [[String: Any]]
    ) -> [String: Any] {
        [
            "observationId": observation.identifier,
            "application": [
                "bundleId": observation.bundleIdentifier,
                "name": MacOperatorProtocol.sanitize(
                    applicationName,
                    maximumCharacters: 160
                ),
            ],
            "window": [
                "title": MacOperatorProtocol.sanitize(windowTitle, maximumCharacters: 240),
                "bounds": rectangleDictionary(observation.windowBounds),
            ],
            "elements": elementSummaries,
            "truncated": elementSummaries.count >= 256,
        ]
    }

    private func invalidateObservation() {
        latestObservation = nil
        latestScreenshotID = nil
    }

    private func onScreenWindows() -> [WindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else {
            return []
        }
        return raw.compactMap { dictionary in
            guard (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = dictionary[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  let ownerName = dictionary[kCGWindowOwnerName as String] as? String,
                  let boundsValue = dictionary[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsValue as CFDictionary
                  ),
                  bounds.width >= 40,
                  bounds.height >= 40,
                  let application = NSRunningApplication(
                      processIdentifier: ownerPID.int32Value
                  ),
                  let bundleIdentifier = application.bundleIdentifier
            else {
                return nil
            }
            return WindowRecord(
                number: CGWindowID(number.uint32Value),
                processIdentifier: ownerPID.int32Value,
                bundleIdentifier: bundleIdentifier,
                applicationName: ownerName,
                title: dictionary[kCGWindowName as String] as? String ?? "",
                bounds: bounds
            )
        }
    }

    private func axValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else {
            return nil
        }
        return result
    }

    private func stringValue(_ element: AXUIElement, attribute: CFString) -> String? {
        axValue(element, attribute: attribute) as? String
    }

    private func boolValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        axValue(element, attribute: attribute) as? Bool
    }

    private func elementBounds(_ element: AXUIElement) -> CGRect? {
        guard let rawPositionValue = axValue(
            element,
            attribute: kAXPositionAttribute as CFString
        ),
            CFGetTypeID(rawPositionValue) == AXValueGetTypeID(),
            let rawSizeValue = axValue(
                element,
                attribute: kAXSizeAttribute as CFString
            ),
            CFGetTypeID(rawSizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let rawPosition = unsafeDowncast(rawPositionValue, to: AXValue.self)
        let rawSize = unsafeDowncast(rawSizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition, .cgPoint, &position),
              AXValueGetValue(rawSize, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func rectangleDictionary(_ rectangle: CGRect) -> [String: Double] {
        [
            "x": rectangle.origin.x,
            "y": rectangle.origin.y,
            "width": rectangle.width,
            "height": rectangle.height,
        ]
    }

    private func boundsDistance(_ left: CGRect, _ right: CGRect) -> Double {
        abs(left.minX - right.minX)
            + abs(left.minY - right.minY)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.72, 0.5, 0.32] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                continue
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { continue }
            if data.length <= 2_000_000 {
                return data as Data
            }
        }
        throw MacOperatorActuatorError.responseOversized
    }

    private static let keyCodes: [MacOperatorKey: CGKeyCode] = [
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

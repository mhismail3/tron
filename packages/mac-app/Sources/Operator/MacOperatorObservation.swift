import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension MacOperatorActuator {
    func applicationsResult() -> [String: Any] {
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

    func createObservation(bundleIdentifier: String) throws -> [String: Any] {
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
        let observation = MacOperatorObservation(
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

    func collectElements(
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

    func redactedLabel(
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

    func allowedActions(_ element: AXUIElement) -> [String] {
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

    func observationResult(
        _ observation: MacOperatorObservation,
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

    func invalidateObservation() {
        latestObservation = nil
        latestScreenshotID = nil
    }

    func onScreenWindows() -> [MacOperatorWindowRecord] {
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
            return MacOperatorWindowRecord(
                number: CGWindowID(number.uint32Value),
                processIdentifier: ownerPID.int32Value,
                bundleIdentifier: bundleIdentifier,
                applicationName: ownerName,
                title: dictionary[kCGWindowName as String] as? String ?? "",
                bounds: bounds
            )
        }
    }

    func axValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else {
            return nil
        }
        return result
    }

    func stringValue(_ element: AXUIElement, attribute: CFString) -> String? {
        axValue(element, attribute: attribute) as? String
    }

    func boolValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        axValue(element, attribute: attribute) as? Bool
    }

    func elementBounds(_ element: AXUIElement) -> CGRect? {
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

    func rectangleDictionary(_ rectangle: CGRect) -> [String: Double] {
        [
            "x": rectangle.origin.x,
            "y": rectangle.origin.y,
            "width": rectangle.width,
            "height": rectangle.height,
        ]
    }

    func boundsDistance(_ left: CGRect, _ right: CGRect) -> Double {
        abs(left.minX - right.minX)
            + abs(left.minY - right.minY)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }
}

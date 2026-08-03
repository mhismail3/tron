import AppKit
import ApplicationServices
import CoreGraphics

extension MacOperatorActuator {
    func requireRunning() throws {
        guard !safety.snapshot().isStopped else {
            invalidateObservation()
            throw MacOperatorActuatorError.emergencyStop
        }
    }

    func currentObservation(
        bundleIdentifier: String,
        observationID: String
    ) throws -> MacOperatorObservation {
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

    func validateFocus(_ observation: MacOperatorObservation) throws {
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
    /// windows in the same app leaves both visible. Match current AX focus and
    /// WindowServer identity before any actuation.
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

    func focusedWindowRecord(
        processIdentifier: pid_t
    ) throws -> (AXUIElement, MacOperatorWindowRecord) {
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
}

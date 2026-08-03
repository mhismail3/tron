import ApplicationServices
import CoreGraphics

struct MacOperatorWindowRecord {
    let number: CGWindowID
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let title: String
    let bounds: CGRect
}

struct MacOperatorObservation {
    let identifier: String
    let safetyGeneration: UInt64
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let windowNumber: CGWindowID
    let windowBounds: CGRect
    let focusedWindow: AXUIElement
    let elements: [String: AXUIElement]
}

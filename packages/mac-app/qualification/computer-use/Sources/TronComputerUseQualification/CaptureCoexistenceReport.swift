import CoreGraphics
import Foundation

/// A capture-only experiment: the fixture changes its own colour. This is not
/// AX/HID control, model-grounded vision, or a production live-view protocol.
struct CaptureCoexistenceReport: Encodable {
    let schema = "tron.computer-use.capture-coexistence.v1"
    let controllerProcessIdentifier: Int32
    let controllerProcessStartIdentity: UInt64
    let executablePath: String
    let windowID: CGWindowID
    let nonce: String
    let bounds: CGRect
    let nativeActions = "not-requested"
    let stimulus = "fixture-owned-colour-change"
    let captureEngine = "ScreenCaptureKit"
    let beforePath: String
    let afterPath: String
    let beforeGreenSamples: Int
    let afterRedSamples: Int
    let windowOrderBefore: [CGWindowID]
    let windowOrderAfter: [CGWindowID]
}

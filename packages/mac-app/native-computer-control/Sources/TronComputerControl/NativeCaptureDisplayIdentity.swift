import ColorSync
import CoreGraphics
import Foundation

/// A display selection is physical/virtual-display identity plus its local
/// coordinate space, not whichever monitor later becomes the primary display.
internal struct NativeCaptureDisplayIdentity: Equatable, Sendable {
    let id: CGDirectDisplayID
    let uuid: String
    let width: Double
    let height: Double
    let pixelsWide: Int
    let pixelsHigh: Int
    let rotation: Double

    func admits(_ current: Self, cropped: Bool) -> Bool {
        current.id == id && current.uuid == uuid && (!cropped || current == self)
    }

    static func read(_ id: CGDirectDisplayID) throws -> Self {
        guard id != kCGNullDirectDisplay, CGDisplayIsActive(id) != 0,
              CGDisplayIsOnline(id) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            throw NativeWindowCaptureError.sourceUnavailable
        }
        let size = CGDisplayBounds(id).size
        let width = Double(size.width), height = Double(size.height)
        let pixelsWide = CGDisplayPixelsWide(id), pixelsHigh = CGDisplayPixelsHigh(id)
        let rotation = CGDisplayRotation(id)
        guard width.isFinite, height.isFinite, rotation.isFinite,
              width > 0, height > 0, pixelsWide > 0, pixelsHigh > 0 else {
            throw NativeWindowCaptureError.sourceUnavailable
        }
        return Self(id: id, uuid: CFUUIDCreateString(nil, uuid) as String,
                    width: width, height: height, pixelsWide: pixelsWide,
                    pixelsHigh: pixelsHigh, rotation: rotation)
    }

    static func active() throws -> [Self] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            throw NativeWindowCaptureError.sourceUnavailable
        }
        return ids.prefix(Int(count)).compactMap { try? read($0) }
    }
}

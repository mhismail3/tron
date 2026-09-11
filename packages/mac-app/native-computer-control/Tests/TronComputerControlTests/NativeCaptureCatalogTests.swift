import CoreGraphics
import Testing
@testable import TronComputerControl

@Suite("Native live source admission")
struct NativeCaptureCatalogTests {
    @Test("Inactive layer-zero surfaces cannot starve the visible-window catalog")
    func inactiveSurface() {
        // Shape observed in the failed installed Activity Monitor selection.
        #expect(!NativeCaptureCatalog.admitsWindow(layer: 0, onScreen: false,
            frame: CGRect(x: 0, y: 0, width: 1800, height: 39)))
        #expect(NativeCaptureCatalog.admitsWindow(layer: 0, onScreen: true,
            frame: CGRect(x: -1000, y: 40, width: 800, height: 600)))
        #expect(!NativeCaptureCatalog.admitsWindow(layer: 25, onScreen: true,
            frame: CGRect(x: 0, y: 0, width: 1800, height: 39)))
    }

    @Test("Invalid and empty window geometry is not offered")
    func invalidGeometry() {
        for rectangle in [CGRect.zero, CGRect.null, CGRect.infinite,
                          CGRect(x: 0, y: 0, width: 0, height: 20),
                          CGRect(x: 100, y: 0, width: -1, height: 20),
                          CGRect(x: 0, y: 100, width: 20, height: -1)] {
            #expect(!NativeCaptureCatalog.admitsWindow(layer: 0, onScreen: true, frame: rectangle))
        }
    }

    @Test("Display crops preserve exact fractional point coordinates")
    func region() throws {
        let region = NativeCaptureRegion(x: 0.5, y: 10, width: 99.5, height: 90)
        let rectangle = try region.rectangle(in: CGSize(width: 100, height: 100))
        #expect(rectangle == CGRect(x: 0.5, y: 10, width: 99.5, height: 90))
        let cropped = ScreenCaptureKitPlatform.configuration(try .init(), sourceRect: rectangle)
        #expect(cropped.sourceRect == rectangle)
        #expect(cropped.width == 1280 && cropped.height == 1280)
        #expect(ScreenCaptureKitPlatform.configuration(try .init()).sourceRect == .zero)
    }

    @Test("Display identity survives layout changes only when the selected scope permits them")
    func displayIdentity() {
        func identity(id: UInt32 = 1, uuid: String = "display", width: Double = 100, rotation: Double = 0) -> NativeCaptureDisplayIdentity {
            .init(id: id, uuid: uuid, width: width, height: 100, pixelsWide: Int(width * 2), pixelsHigh: 200, rotation: rotation)
        }
        let selected = identity()
        #expect(selected.admits(identity(), cropped: true))
        #expect(selected.admits(identity(width: 200), cropped: false))
        #expect(!selected.admits(identity(width: 200), cropped: true))
        #expect(selected.admits(identity(rotation: 90), cropped: false))
        #expect(!selected.admits(identity(rotation: 90), cropped: true))
        #expect(!selected.admits(identity(id: 2), cropped: false))
        #expect(!selected.admits(identity(uuid: "different-display"), cropped: false))
    }

    @Test("A crop cannot widen, clamp, wrap, or move outside its selected display")
    func invalidRegions() {
        for region in [
            NativeCaptureRegion(x: -1, y: 0, width: 10, height: 10),
            NativeCaptureRegion(x: 0, y: -1, width: 10, height: 10),
            NativeCaptureRegion(x: 90, y: 0, width: 11, height: 10),
            NativeCaptureRegion(x: 0, y: 90, width: 10, height: 11),
            NativeCaptureRegion(x: 0, y: 0, width: 0, height: 10),
            NativeCaptureRegion(x: 0, y: 0, width: -10, height: 10),
            NativeCaptureRegion(x: .infinity, y: 0, width: 10, height: 10),
            NativeCaptureRegion(x: 0, y: .nan, width: 10, height: 10),
            NativeCaptureRegion(x: 0, y: 0, width: .greatestFiniteMagnitude, height: 10),
        ] {
            #expect(throws: NativeWindowCaptureError.self) {
                try region.rectangle(in: CGSize(width: 100, height: 100))
            }
        }
    }
}

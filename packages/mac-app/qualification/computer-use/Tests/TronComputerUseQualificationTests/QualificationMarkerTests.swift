import CoreGraphics
import XCTest
@testable import TronComputerUseQualification

final class QualificationMarkerTests: XCTestCase {
    private func image(space: CFString, components: [CGFloat]) throws -> CGImage {
        let colourSpace = try XCTUnwrap(CGColorSpace(name: space))
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 80,
            bitsPerComponent: 8, bytesPerRow: 400, space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colourSpace, components: components)))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        return try XCTUnwrap(context.makeImage())
    }

    func testWideGamutAndSRGBGreenAreObservedAsGreen() throws {
        for space in [CGColorSpace.displayP3, CGColorSpace.sRGB] {
            let result = try QualificationMarkerOracle.samples(in: image(space: space, components: [0.08, 0.72, 0.12, 1]))
            XCTAssertEqual(result.green, 8_000)
            XCTAssertEqual(result.red, 0)
        }
    }

    func testWideGamutRedIsNotAStaleGreenFrame() throws {
        let result = try QualificationMarkerOracle.samples(in: image(space: CGColorSpace.displayP3, components: [0.88, 0.08, 0.08, 1]))
        XCTAssertEqual(result.red, 8_000)
        XCTAssertEqual(result.green, 0)
    }

    func testBlankAndTransparentFramesCannotSatisfyTheMarkerOracle() throws {
        let colours: [[CGFloat]] = [[1, 1, 1, 1], [0, 0, 0, 1], [0.08, 0.72, 0.12, 0]]
        for colour in colours {
            let result = try QualificationMarkerOracle.samples(in: image(space: CGColorSpace.displayP3, components: colour))
            XCTAssertEqual(result.red + result.green, 0)
        }
    }
}

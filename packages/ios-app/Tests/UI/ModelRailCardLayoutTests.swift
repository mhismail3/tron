import SwiftUI
import Testing
import UIKit
@testable import TronMobile

/// Rail-card layout stability.
///
/// Failure mode written first: selecting a card inserts its checkmark into the
/// header flow, which is taller than the provider caption, so the model name
/// and facts shift down by a few points (visible jitter on tap). Every pixel
/// outside the checkmark's own corner must be identical in both states.
@MainActor
@Suite("Model rail card layout")
struct ModelRailCardLayoutTests {
    @Test("selecting a card moves nothing but the checkmark")
    func selectionDoesNotShiftContent() throws {
        let model = ModelSummary(
            provider: "anthropic", id: "claude-opus-5-5", name: "Claude Opus 5.5",
            reasoning: true, input: ["text"], contextWindow: 1_000_000, maxTokens: 128_000,
            available: true, releaseDate: "2026-09-22", cost: ModelTokenPrice(input: 4, output: 20)
        )
        let plain = try pixels(ModelRailCard(model: model, selectionAccent: nil))
        let selected = try pixels(ModelRailCard(model: model, selectionAccent: .tronPurple))
        #expect(plain.width == selected.width && plain.height == selected.height,
                "selection changed card size")
        // The checkmark may only paint inside the top-trailing 36x36 pt corner.
        let corner = Int(36 * plain.scale)
        var differing = 0
        for y in 0..<min(plain.height, selected.height) {
            for x in 0..<min(plain.width, selected.width) where !(y < corner && x >= plain.width - corner) {
                if plain.pixel(x, y) != selected.pixel(x, y) { differing += 1 }
            }
        }
        #expect(differing == 0, "\(differing) pixels moved outside the checkmark corner")
    }

    private struct Bitmap {
        let width: Int, height: Int, scale: CGFloat
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            let i = (y * width + x) * 4
            return UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
    }

    private func pixels<V: View>(_ view: V) throws -> Bitmap {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Bitmap(width: width, height: height, scale: 2, bytes: bytes)
    }
}

import Foundation
import Testing
@testable import TronMobile

/// `NativeExtensionText` is the shared display sanitizer for extension-provided
/// text (widget lines, frame lines and runs, interactive frame content). Its
/// patterns are now compiled once instead of per call, so these checks pin the
/// behavior that optimization must preserve.
@Suite("Native extension text")
struct NativeExtensionTextTests {

    @Test("terminal detail hints are dropped rather than shown")
    func detailHintsAreRemoved() {
        // The `live detail` form is a hint on its own.
        #expect(NativeExtensionText.isDetailHint("press   live  detail."))
        #expect(NativeExtensionText.isDetailHint("Press g live detail"))
        // The `to inspect` form is only a hint when the producer also emitted its
        // navigation glyph, so a plain instruction stays visible.
        #expect(NativeExtensionText.isDetailHint("Press x to inspect ↓"))
        #expect(NativeExtensionText.isDetailHint("Press → to inspect"))
        #expect(!NativeExtensionText.isDetailHint("Press d to inspect"))
        #expect(!NativeExtensionText.isDetailHint("to inspect the file"))
        #expect(NativeExtensionText.clean("Press x to inspect ↓") == "")
        #expect(NativeExtensionText.clean("to inspect the file") == "to inspect the file")
        // Ordinary goal/status text is never mistaken for a hint.
        #expect(!NativeExtensionText.isDetailHint("Goal active"))
        #expect(!NativeExtensionText.isDetailHint("Running: read file.swift"))
    }

    @Test("links are admitted only for safe schemes")
    func safeLinkSchemes() {
        #expect(NativeExtensionText.safeURL("https://example.com/doc")?.absoluteString == "https://example.com/doc")
        #expect(NativeExtensionText.safeURL("mailto:someone@example.com") != nil)
        #expect(NativeExtensionText.safeURL("javascript:alert(1)") == nil)
        #expect(NativeExtensionText.safeURL("file:///etc/passwd") == nil)
        #expect(NativeExtensionText.safeURL("https://") == nil)
        #expect(NativeExtensionText.safeURL("not a url") == nil)
    }
}

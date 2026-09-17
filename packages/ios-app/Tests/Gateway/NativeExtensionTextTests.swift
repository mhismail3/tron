import Foundation
import Testing
@testable import TronMobile

/// `NativeExtensionText` is the shared display sanitizer for extension-provided
/// text (widget lines, frame lines and runs, interactive frame content). Its
/// patterns are now compiled once instead of per call, so these checks pin the
/// behavior that optimization must preserve.
@Suite("Native extension text")
struct NativeExtensionTextTests {
    @Test("whitespace collapses to single spaces and trims")
    func whitespaceNormalization() {
        #expect(NativeExtensionText.clean("  Goal   active  ") == "Goal active")
        #expect(NativeExtensionText.clean("multi\n line\ntext") == "multi line text")
        #expect(NativeExtensionText.clean("tab\tseparated") == "tab separated")
        #expect(NativeExtensionText.clean("already clean") == "already clean")
        #expect(NativeExtensionText.clean("   ") == "")
        #expect(NativeExtensionText.clean("") == "")
    }

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

    @Test("a frame's presentable rows keep only sanitized, non-hint lines")
    func frameRowPreparation() {
        // Mirrors ExtensionFrameView's single preparation pass: `clean` both
        // sanitizes and drops hints, so a hint-only frame renders nothing and the
        // joined accessibility value uses the same prepared text.
        let lines = ["  Frame progress 3 of 5 ", "", "Press x to inspect ↓", "Usage: tokens 12k/50k, time 4m 12s"]
        let prepared = lines.compactMap { line -> String? in
            let cleaned = NativeExtensionText.clean(line)
            return cleaned.isEmpty ? nil : cleaned
        }
        #expect(prepared == ["Frame progress 3 of 5", "Usage: tokens 12k/50k, time 4m 12s"])
        #expect(prepared.joined(separator: "\n") == "Frame progress 3 of 5\nUsage: tokens 12k/50k, time 4m 12s")
        #expect(["", "Press x to inspect ↓", "   "].compactMap { NativeExtensionText.clean($0).isEmpty ? nil : $0 }.isEmpty)
    }
}

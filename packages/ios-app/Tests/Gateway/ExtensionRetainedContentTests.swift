import Foundation
import Testing
@testable import TronMobile

/// Retained extension content is presentation-only and derived from the
/// authoritative snapshot. These checks protect the admission rules that keep
/// unsupported or empty extension state out of the general widgets sheet.
@Suite("Extension retained content")
struct ExtensionRetainedContentTests {
    private func widget(
        key: String,
        lines: [String],
        placement: ExtensionWidget.Placement = .aboveEditor,
        owner: ExtensionOwner? = nil
    ) -> ExtensionWidget {
        ExtensionWidget(key: key, revision: 1, lines: lines, placement: placement, owner: owner)
    }

    private func surface(
        id: String,
        kind: ExtensionSurface.Kind,
        lifecycle: ExtensionSurface.Lifecycle = .retained,
        frameLines: [String]
    ) -> ExtensionSurface {
        ExtensionSurface(
            id: id,
            kind: kind,
            placement: .fullscreen,
            lifecycle: lifecycle,
            targetId: nil,
            provenance: .init(source: "npm:@example/extension", path: nil),
            revision: 1,
            focused: false,
            inputMode: .none,
            frame: ExtensionFrame(
                width: 40,
                height: frameLines.count,
                lines: frameLines.map { ExtensionFrameLine(plainText: $0, runs: []) },
                plainText: frameLines.joined(separator: "\n")
            )
        )
    }

    @Test("no retained content means no sheet entry point")
    func emptyContentIsNotPresentable() {
        #expect(ExtensionRetainedContentPolicy.content(widgets: nil, surfaces: nil).isEmpty)
        #expect(ExtensionRetainedContentPolicy.content(widgets: [], surfaces: []).isEmpty)
        // A widget whose only lines are blank or terminal detail hints carries
        // no user-visible content and must not open an empty sheet.
        let empty = widget(key: "goal", lines: ["   ", "", "Press x to inspect ↓"])
        #expect(ExtensionRetainedContentPolicy.content(widgets: [empty], surfaces: nil).isEmpty)
    }

    @Test("string widgets contribute cleaned non-empty lines in authoritative order")
    func stringWidgetLines() {
        let content = ExtensionRetainedContentPolicy.content(
            widgets: [
                widget(key: "b", lines: ["  second  ", ""], owner: .init(id: "owner-b", title: "Beta", source: "npm:beta")),
                widget(key: "a", lines: ["first"], owner: .init(id: "owner-a", title: "Alpha", source: "npm:alpha")),
            ],
            surfaces: nil
        )
        #expect(content.entries.map(\.id) == ["widget:b", "widget:a"])
        #expect(content.entries[0].style == .text(["second"]))
        // Producer order follows first appearance so the list never reshuffles.
        #expect(content.producers == ["Beta", "Alpha"])
    }

    @Test("only retained non-blocking widget surfaces are presentable")
    func surfaceAdmission() {
        let content = ExtensionRetainedContentPolicy.content(
            widgets: nil,
            surfaces: [
                surface(id: "surface:blocking", kind: .widget, lifecycle: .blocking, frameLines: ["blocked"]),
                surface(id: "surface:custom", kind: .custom, frameLines: ["custom"]),
                surface(id: "surface:overlay", kind: .overlay, frameLines: ["overlay"]),
                surface(id: "surface:b", kind: .widget, frameLines: ["second"]),
                surface(id: "surface:a", kind: .widget, frameLines: ["first"]),
                surface(id: "surface:empty", kind: .widget, frameLines: []),
            ]
        )
        // Blocking, unsupported kinds, and empty frames are excluded; the
        // remaining widget surfaces order deterministically by identity.
        #expect(content.entries.map(\.id) == ["surface:surface:a", "surface:surface:b"])
        #expect(content.entries.allSatisfy { entry in
            if case .frame = entry.style { return true }
            return false
        })
    }

    @Test("unknown producers group last and merge into one section")
    func unknownProducerGrouping() {
        let content = ExtensionRetainedContentPolicy.content(
            widgets: [
                widget(key: "known", lines: ["k"], owner: .init(id: "owner", title: "Owner", source: "npm:pkg")),
                widget(key: "unknown-1", lines: ["u1"]),
                widget(key: "unknown-2", lines: ["u2"]),
            ],
            surfaces: nil
        )
        #expect(content.producers == ["Owner", ExtensionRetainedContent.unknownProducer])
        #expect(content.entries(forProducer: ExtensionRetainedContent.unknownProducer).count == 2)
    }

    @Test("surface producers never invent a friendlier identity than provenance")
    func surfaceProducerTitle() {
        #expect(ExtensionRetainedContentPolicy.surfaceProvenanceTitle("npm:@example/extension") == "npm:@example/extension")
        #expect(ExtensionRetainedContentPolicy.surfaceProvenanceTitle("  inline  ") == "inline")
        #expect(ExtensionRetainedContentPolicy.surfaceProvenanceTitle(nil) == ExtensionRetainedContent.unknownProducer)
        #expect(ExtensionRetainedContentPolicy.surfaceProvenanceTitle("") == ExtensionRetainedContent.unknownProducer)
        #expect(ExtensionRetainedContentPolicy.surfaceProvenanceTitle("   ") == ExtensionRetainedContent.unknownProducer)
        // A long resolver string is bounded rather than allowed to overflow a
        // section header.
        let long = String(repeating: "a", count: 200)
        let bounded = ExtensionRetainedContentPolicy.surfaceProvenanceTitle(long)
        #expect(bounded.count == ExtensionRetainedContentPolicy.maximumProvenanceTitleLength + 1)
        #expect(bounded.hasSuffix("…"))
    }
}

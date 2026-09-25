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
        frameLines: [String],
        source: String? = "npm:@example/extension"
    ) -> ExtensionSurface {
        ExtensionSurface(
            id: id,
            kind: kind,
            placement: .fullscreen,
            lifecycle: lifecycle,
            targetId: nil,
            provenance: .init(source: source, path: nil),
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

    @Test("pi-subagents owned retained state is excluded while unknown state remains")
    func subagentOwnedContentFiltering() {
        let content = ExtensionRetainedContentPolicy.content(
            widgets: [
                widget(key: "subagent", lines: ["private tracker"], owner: .init(id: "subagents", title: "Pi Subagents", source: "npm:pi-subagents@0.59.0")),
                widget(key: "unknown", lines: ["keep this"], owner: nil),
                widget(key: "different-package", lines: ["keep similarly named producer"], owner: .init(id: "different", title: "Pi Subagents", source: "npm:pi-subagents-helper@1.0"))
            ],
            surfaces: [surface(id: "subagent-frame", kind: .widget, frameLines: ["private frame"], source: "npm:pi-subagents"),
                       surface(id: "unknown-frame", kind: .widget, frameLines: ["keep frame"], source: nil)],
            statuses: ["subagent": "private status", "unknown": "keep status"],
            statusOwners: ["subagent": .init(id: "subagents", title: "Pi Subagents", source: "npm:pi-subagents@0.59.0")]
        )
        #expect(content.entries.map(\.id) == ["widget:unknown", "widget:different-package", "surface:unknown-frame", "status:unknown"])
        #expect(content.entries.contains { $0.producer == "Pi Subagents" })
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

    @Test("a status outlives its cleared widget so a paused goal stays inspectable")
    func statusOnlyContent() {
        // The real pi-goal shape: while a goal is paused it clears its widget and
        // leaves only `setStatus("pi-goal", "Goal paused (/goal resume)")`. Before
        // retained statuses were presentable this produced no content at all, so
        // the composer entry point disappeared and the state was unreachable.
        let content = ExtensionRetainedContentPolicy.content(
            widgets: nil,
            surfaces: nil,
            statuses: ["pi-goal": "Goal paused (/goal resume)"],
            statusOwners: ["pi-goal": .init(id: "owner-goal", title: "Goal", source: "npm:@mocito/pi-goal")]
        )
        #expect(!content.isEmpty)
        #expect(content.producers == ["Goal"])
        #expect(content.entries == [.init(id: "status:pi-goal", producer: "Goal", style: .status("Goal paused (/goal resume)"))])
    }

    @Test("statuses normalize whitespace, drop empties, and order by key")
    func statusPresentation() {
        let content = ExtensionRetainedContentPolicy.content(
            widgets: nil,
            surfaces: nil,
            statuses: [
                "z": "  multitask \n running  ",
                "a": "one line",
                "blank": "   ",
                "empty": "",
            ],
            statusOwners: nil
        )
        // Wire dictionaries are unordered, so key order is the stability rule.
        #expect(content.entries.map(\.id) == ["status:a", "status:z"])
        #expect(content.entries.map(\.style) == [.status("one line"), .status("multitask running")])
        // An ownerless status is grouped rather than dropped or guessed.
        #expect(content.producers == [ExtensionRetainedContent.unknownProducer])
        // A status is not subject to the widget detail-hint filter.
        #expect(ExtensionRetainedContentPolicy.presentableStatusText("Press x to inspect ↓") == "Press x to inspect ↓")
    }
}

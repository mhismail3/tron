import Foundation
import Testing
@testable import TronMobile

@Suite("Thinking slider")
struct ThinkingSliderTests {
    @Test("stops preserve runtime order and raw values without aliases or invented levels")
    func supportedStops() {
        let scale = ThinkingSliderScale(levels: ["off", "high", "high", "xhigh", "adaptive", "", "  "])
        #expect(scale.levels == ["off", "high", "xhigh", "adaptive"])
        #expect(scale.progress(for: "medium") == nil)
        #expect(scale.progress(for: "Extra High") == nil)
        #expect(scale.progress(for: "off") == 0)
        #expect(scale.progress(for: "adaptive") == 1)
        for level in scale.levels {
            #expect(scale.progress(for: level).flatMap(scale.level) == level)
        }
        for raw in stride(from: -0.2, through: 1.2, by: 0.001) {
            #expect(scale.level(at: raw).map(scale.levels.contains) == true)
        }
        #expect(scale.level(at: .nan) == nil)
        #expect(scale.level(at: .infinity) == nil)
        #expect(scale.level(at: -.infinity) == nil)
    }

    @Test("empty and singleton lists never manufacture a choice")
    func degenerateLists() {
        let empty = ThinkingSliderScale(levels: [])
        #expect(empty.level(at: 0.5) == nil)
        #expect(empty.adjacent(to: "off", increasing: true) == nil)
        #expect(empty.adjacent(to: "off", increasing: false) == nil)
        let singleton = ThinkingSliderScale(levels: ["off"])
        #expect(singleton.progress(for: "off") == 0.5)
        #expect(singleton.level(at: -10) == "off")
        #expect(singleton.level(at: 10) == "off")
        #expect(singleton.adjacent(to: "off", increasing: true) == "off")
        #expect(singleton.adjacent(to: "off", increasing: false) == "off")
    }

    @Test("discrete finger selection and accessibility stepping stay ordered and bounded")
    func stepping() {
        let scale = ThinkingSliderScale(levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
        var previous = 0
        for raw in stride(from: 0.0, through: 1.0, by: 0.001) {
            let index = scale.levels.firstIndex(of: scale.level(at: raw)!)!
            #expect(index >= previous)
            previous = index
        }
        #expect(scale.adjacent(to: "off", increasing: false) == "off")
        #expect(scale.adjacent(to: "max", increasing: true) == "max")
        #expect(scale.adjacent(to: "high", increasing: true) == "xhigh")
        #expect(scale.adjacent(to: "xhigh", increasing: false) == "high")
        #expect(scale.adjacent(to: "unlisted", increasing: true) == "off")
        #expect(scale.adjacent(to: "unlisted", increasing: false) == "max")
    }

    @Test("preview, return-to-original, stale values and removed choices produce no commit")
    func deferredDraft() {
        let scale = ThinkingSliderScale(levels: ["off", "high", "xhigh"])
        var draft = ThinkingSliderDraft(value: "high")
        #expect(draft.selectionToCommit(currentValue: "high", levels: scale.levels) == nil)
        draft.select("off", in: scale)
        draft.select("xhigh", in: scale)
        #expect(draft.original == "high")
        #expect(draft.selectionToCommit(currentValue: "high", levels: scale.levels) == "xhigh")
        #expect(draft.selectionToCommit(currentValue: "off", levels: scale.levels) == nil)
        #expect(draft.selectionToCommit(currentValue: "high", levels: ["off", "high"]) == nil)
        draft.select("medium", in: scale)
        #expect(draft.value == "xhigh")
        draft.select("high", in: scale)
        #expect(draft.selectionToCommit(currentValue: "high", levels: scale.levels) == nil)
        var unknown = ThinkingSliderDraft(value: "unlisted")
        #expect(unknown.selectionToCommit(currentValue: "unlisted", levels: scale.levels) == nil)
        unknown.select("xhigh", in: scale)
        #expect(unknown.selectionToCommit(currentValue: "unlisted", levels: scale.levels) == "xhigh")
    }

    @Test("transition diagnostics retire interrupted phases and ignore stale completions")
    @MainActor func transitionDiagnosticsRespectOwner() {
        let presentation = ConfigurationSliderPresentation()
        let recorder = RecordingPerformanceSignposts()
        let first = presentation.open(owner: UUID())
        presentation.beginMeasurement(.configurationSliderExpand, for: first, recorder: recorder)
        #expect(presentation.beginClosing(first))
        presentation.beginMeasurement(.configurationSliderCollapse, for: first, recorder: recorder)
        presentation.completeExpansion(first)
        let second = presentation.open(owner: UUID())
        presentation.beginMeasurement(.configurationSliderExpand, for: second, recorder: recorder)
        presentation.finish(first) { Issue.record("Stale editor committed") }
        presentation.cancel(first)
        presentation.completeExpansion(second)
        presentation.cancel(second)
        #expect(recorder.events() == [
            .begin(.configurationSliderExpand), .end(.configurationSliderExpand, .cancelled, .none),
            .begin(.configurationSliderCollapse), .end(.configurationSliderCollapse, .cancelled, .none),
            .begin(.configurationSliderExpand), .end(.configurationSliderExpand, .success, .none)
        ])
    }

    @Test("one host admits one editor and only its exact close may commit once")
    @MainActor func singleEditorAndCompletion() {
        let presentation = ConfigurationSliderPresentation()
        let context = presentation.open(owner: UUID())
        let thinking = presentation.open(owner: UUID())
        var writes: [String] = []
        #expect(!presentation.admitsInput(context))
        #expect(!presentation.beginClosing(context))
        presentation.finish(thinking) { writes.append("premature") }
        #expect(writes.isEmpty)
        #expect(presentation.beginClosing(thinking))
        #expect(!presentation.admitsInput(thinking))
        #expect(!presentation.beginClosing(thinking))
        presentation.finish(context) { writes.append("stale") }
        presentation.finish(thinking) { writes.append("xhigh") }
        presentation.finish(thinking) { writes.append("duplicate") }
        #expect(writes == ["xhigh"])
        #expect(presentation.session == nil)
    }

    @Test("cancelled or replaced generations cannot mutate or cancel a reopened same-owner editor")
    @MainActor func replacementAndRetirement() {
        let presentation = ConfigurationSliderPresentation()
        let owner = UUID()
        let old = presentation.open(owner: owner)
        #expect(presentation.beginClosing(old))
        let replacement = presentation.open(owner: owner)
        presentation.cancel(old)
        presentation.finish(old) { Issue.record("Old completion wrote into the replacement") }
        #expect(presentation.admitsInput(replacement))
        presentation.cancel(owner: UUID())
        #expect(presentation.admitsInput(replacement))
        presentation.cancel(owner: owner)
        presentation.finish(replacement) { Issue.record("Retired source committed") }
        let reopened = presentation.open(owner: owner)
        #expect(reopened != old && reopened != replacement)
        #expect(presentation.admitsInput(reopened))
    }
}

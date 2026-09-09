import SwiftUI

/// Runtime order and raw values are authoritative. Display aliases must never
/// invent a supported level or change the string eventually sent to the Mac.
struct ThinkingSliderScale {
    let levels: [String]

    init(levels: [String]) {
        var seen = Set<String>()
        self.levels = levels.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }

    func progress(for level: String) -> Double? {
        guard let index = levels.firstIndex(of: level) else { return nil }
        return levels.count == 1 ? 0.5 : Double(index) / Double(levels.count - 1)
    }

    func level(at progress: Double) -> String? {
        guard !levels.isEmpty, progress.isFinite else { return nil }
        return levels[Int((min(1, max(0, progress)) * Double(levels.count - 1)).rounded())]
    }

    func adjacent(to level: String, increasing: Bool) -> String? {
        guard let index = levels.firstIndex(of: level) else { return increasing ? levels.first : levels.last }
        return levels[min(levels.count - 1, max(0, index + (increasing ? 1 : -1)))]
    }
}

struct ThinkingSliderDraft {
    let original: String
    private(set) var value: String

    init(value: String) { original = value; self.value = value }

    mutating func select(_ level: String, in scale: ThinkingSliderScale) {
        guard scale.levels.contains(level) else { return }
        value = level
    }

    func selectionToCommit(currentValue: String, levels: [String]) -> String? {
        guard currentValue == original, value != original, levels.contains(value) else { return nil }
        return value
    }
}

struct ThinkingSliderRequest {
    let scale: ThinkingSliderScale
    let value: String
    let finish: (ThinkingSliderDraft) -> Void
}

struct ThinkingSliderEditor: View {
    let request: ThinkingSliderRequest
    let anchor: ConfigurationSliderRequest
    let source: CGRect
    let availableSize: CGSize
    let presentation: ConfigurationSliderPresentation
    @State private var draft: ThinkingSliderDraft
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: ThinkingSliderRequest, anchor: ConfigurationSliderRequest, source: CGRect,
         availableSize: CGSize, presentation: ConfigurationSliderPresentation) {
        self.request = request
        self.anchor = anchor
        self.source = source
        self.availableSize = availableSize
        self.presentation = presentation
        _draft = State(initialValue: ThinkingSliderDraft(value: request.value))
    }

    var body: some View {
        let progress = request.scale.progress(for: draft.value)
        let title = ThinkingLevelPresentation.title(draft.value)
        ConfigurationSliderContainer(
            title: "Thinking", value: title, collapsedTitle: title,
            anchor: anchor, source: source, availableSize: availableSize, presentation: presentation,
            finish: { request.finish(draft) }
        ) { actions in
            ConfigurationSliderTrack(
                progress: progress ?? 0, stops: request.scale.levels.compactMap(request.scale.progress),
                emphasizedStop: progress, showsThumb: progress != nil, accent: anchor.accent,
                title: "Thinking", value: title,
                hint: (progress == nil ? "Current value is not in the available choices. " : "")
                    + "Available levels: \(request.scale.levels.map(ThinkingLevelPresentation.title).joined(separator: ", ")). Drag or adjust to choose a level. Dismiss to save.",
                identifier: "thinking-level-slider", feedback: request.scale.levels.firstIndex(of: draft.value), actions: actions,
                change: { raw, _ in
                    guard let level = request.scale.level(at: raw), level != draft.value else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { draft.select(level, in: request.scale) }
                },
                settle: { _, _ in }, // Thinking is discrete during the drag, not just on release.
                adjust: { increasing in
                    if let level = request.scale.adjacent(to: draft.value, increasing: increasing) {
                        draft.select(level, in: request.scale)
                    }
                }
            )
        }
    }
}

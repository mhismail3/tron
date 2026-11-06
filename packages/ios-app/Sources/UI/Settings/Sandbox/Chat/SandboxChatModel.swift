import Foundation
import SwiftUI

/// The chat prototype's state, one owner per concern (docs/design-language.md
/// › State owners). All content is fake; nothing reads or writes the Gateway.
@Observable @MainActor
final class SandboxChatModel {
    struct Tool: Identifiable, Hashable {
        enum Family: String { case read, edit, shell, search, web }
        enum Status { case running, done, failed }
        let id: Int
        let family: Family
        let label: String
        var status: Status
        var detail: String
    }

    enum Entry: Identifiable, Hashable {
        case user(id: Int, text: String)
        case assistant(id: Int, text: String)
        case tools(id: Int, [Tool])

        var id: Int {
            switch self {
            case .user(let id, _), .assistant(let id, _), .tools(let id, _): id
            }
        }
    }

    /// A finished piece of work the feedback capsule reports.
    struct Event: Identifiable, Hashable {
        let id: Int
        let icon: String
        let title: String
        let detail: String
        let tint: Color
    }

    enum Overlay: Equatable {
        case none
        case context
        case events
    }

    // Transcript
    var entries: [Entry]
    /// Chip groups expanded in place, by entry id.
    var expandedTools: Set<Int> = []

    // Draft: survives the keyboard and every overlay.
    var draft = ""

    // Context picker
    static let contexts = [("Gateway audit", "tron · main"), ("Sandbox sheet", "tron · feat/2302"),
                           ("Garden plan", "notes · home")]
    var context = 0

    // Feedback: the events are the state; collapsed is only their form.
    var events: [Event] = []
    var feedbackCollapsed = false

    // Overlays
    var overlay: Overlay = .none
    var selectedEvent: Event?

    // Motion
    /// The liquid action menu's one progress target: 0 closed, 1 open.
    var menuOpen = false
    /// The menu's circles exist from opening until a close settles, so a closed
    /// menu leaves no glass behind the trigger.
    var menuMounted = false

    @ObservationIgnored private var nextID = 100
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    init() {
        entries = Self.seed
        events = [Event(id: 1, icon: "pencil", title: "Edited 2 files", detail: "SandboxDesign.swift, SandboxChatView.swift",
                        tint: .tronAmber),
                  Event(id: 2, icon: "checkmark.seal", title: "Tests passed", detail: "4 of 4 Sandbox journeys", tint: .tronEmerald),
                  Event(id: 3, icon: "arrow.triangle.branch", title: "Pushed branch", detail: "feat/2304-design-language", tint: .tronSky)]
        feedbackCollapsed = true
    }

    var contextTitle: String { Self.contexts[context].0 }
    var contextDetail: String { Self.contexts[context].1 }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        nextID += 1
        entries.append(.user(id: nextID, text: text))
        nextID += 1
        entries.append(.assistant(id: nextID, text: "Noted. This prototype only echoes: \u{201C}\(text)\u{201D}."))
    }

    /// A new event shows as readable feedback, then collapses into the cluster.
    func report(_ event: Event, collapseAfter seconds: Double = 2.5, animation: Animation) {
        events.insert(event, at: 0)
        withAnimation(animation) { feedbackCollapsed = false }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            withAnimation(animation) { self.feedbackCollapsed = true }
        }
    }

    func makeEvent(_ icon: String, _ title: String, _ detail: String, _ tint: Color) -> Event {
        nextID += 1
        return Event(id: nextID, icon: icon, title: title, detail: detail, tint: tint)
    }

    private static let seed: [Entry] = [
        .user(id: 1, text: "What changed in the Gateway overnight?"),
        .tools(id: 2, [
            Tool(id: 21, family: .search, label: "Searched “rollover” in gateway", status: .done, detail: "14 matches in 5 files"),
            Tool(id: 22, family: .read, label: "Read HomeLifecycle.ts", status: .done, detail: "412 lines"),
            Tool(id: 23, family: .shell, label: "git log --since=yesterday", status: .done, detail: "9 commits"),
        ]),
        .assistant(id: 3, text: "Two workers finished overnight. The docs sweep landed on main, and the audit is waiting for your review. Memory is current through chapter 18, and nothing is blocked."),
        .user(id: 4, text: "Open the audit and summarize what it found."),
        .tools(id: 5, [
            Tool(id: 51, family: .read, label: "Read audit-report.md", status: .done, detail: "3 findings"),
            Tool(id: 52, family: .edit, label: "Edited AGENTS.md", status: .failed, detail: "Refused: maintainer-only file"),
        ]),
        .assistant(id: 6, text: "The audit found three things: a stale lease file after crashes, one retry loop without a bound, and a doc that still names a retired script. I couldn't edit AGENTS.md; it's maintainer-only."),
        .user(id: 7, text: "Fix the retry loop."),
        .tools(id: 8, [
            Tool(id: 81, family: .edit, label: "Edited RetryPolicy.ts", status: .done, detail: "+12 −4"),
            Tool(id: 82, family: .shell, label: "npm test retry", status: .running, detail: "Running 38 tests"),
        ]),
    ]
}

import SwiftUI
import TronMobileCore

/// What the mounted chat's live haptics key on, read from its authoritative
/// snapshot on every render. Streaming text never changes these facts.
struct ChatLiveHapticFacts: Equatable {
    /// One uninterrupted live view of the chat: its presentation, the installed
    /// Gateway subscription (a reconnect installs a new one) and an active,
    /// uncovered, ready surface. Nil while any of those is missing.
    struct Epoch: Equatable {
        let generation: Int
        let subscription: String
    }

    let epoch: Epoch?
    let phase: SessionPhase?
    let tailID: String?
    /// The pending question whose sheet the chat presents now.
    let questionID: String?
}

/// Turns changes the chat observes live into at most one haptic each. Every
/// new epoch adopts what is on screen as its baseline, so an opened, restored,
/// reconnected or re-foregrounded chat plays nothing for what it already
/// shows, and older history paged in above the tail is never "new".
struct ChatLiveHapticLedger {
    private var epoch: ChatLiveHapticFacts.Epoch?
    private var tailID: String?
    private var watchingRun = false
    private var runStartTailID: String?
    private var settlePending = false
    /// Event identities already played (or adopted), most recent last.
    private var played: [String] = []

    mutating func observe(_ facts: ChatLiveHapticFacts, transcript: [TranscriptItem]) -> TronHaptic? {
        guard let epoch = facts.epoch else {
            self.epoch = nil
            return nil
        }
        guard epoch == self.epoch else {
            self.epoch = epoch
            tailID = facts.tailID
            watchingRun = facts.phase?.isActive == true
            runStartTailID = facts.tailID
            settlePending = false
            if let question = facts.questionID { _ = admit("question:\(question)") }
            return nil
        }
        let previousTailID = tailID
        let appended = facts.tailID == previousTailID ? [] : Self.items(after: previousTailID, in: transcript)
        tailID = facts.tailID

        if facts.phase?.isActive == true {
            if !watchingRun { runStartTailID = previousTailID }
            watchingRun = true
            settlePending = false
        } else if facts.phase == .idle {
            if watchingRun { settlePending = true }
            watchingRun = false
        } else {
            // An interrupted session did not settle normally.
            watchingRun = false
            settlePending = false
        }

        var haptic: TronHaptic?
        if let question = facts.questionID, admit("question:\(question)") {
            haptic = .questionPresented
        }
        // The run's final assistant message can land with the idle phase or
        // just after it; Stop and failures end with `aborted`/`error`.
        if settlePending,
           let final = Self.items(after: runStartTailID, in: transcript)
               .last(where: { $0.kind == .message && $0.role == .assistant }) {
            settlePending = false
            if final.stopReason == "stop", admit("finish:\(final.id)") { haptic = haptic ?? .runFinished }
        }
        var worker = false
        for item in appended where Self.isWorkerMessage(item) {
            if admit("worker:\(item.id)") { worker = true }
        }
        if worker { haptic = haptic ?? .workerMessage }
        return haptic
    }

    static func isWorkerMessage(_ item: TranscriptItem) -> Bool {
        item.kind == .customMessage
            && item.semantic?.direction != .hiddenInternal
            && InboundContextMessagePresentation(
                origin: item.semantic?.origin, customType: item.customType, details: item.details
            ).fromWorker
    }

    /// Items after `id`, scanning from the tail; everything when there was no
    /// tail, nothing when the tail is no longer in this window.
    private static func items(after id: String?, in transcript: [TranscriptItem]) -> ArraySlice<TranscriptItem> {
        guard let id else { return transcript[...] }
        guard let index = transcript.lastIndex(where: { $0.id == id }) else { return [] }
        return transcript[(index + 1)...]
    }

    private mutating func admit(_ identity: String) -> Bool {
        guard !played.contains(identity) else { return false }
        played.append(identity)
        if played.count > 128 { played.removeFirst(played.count - 128) }
        return true
    }
}

/// Plays the mounted chat's live haptics; shared by Home and every session chat.
struct ChatLiveHapticsModifier: ViewModifier {
    let facts: ChatLiveHapticFacts
    let transcript: () -> [TranscriptItem]
    @State private var ledger = ChatLiveHapticLedger()

    func body(content: Content) -> some View {
        content.onChange(of: facts, initial: true) { _, facts in
            if let haptic = ledger.observe(facts, transcript: transcript()) {
                TronHaptics.shared.play(haptic)
            }
        }
    }
}

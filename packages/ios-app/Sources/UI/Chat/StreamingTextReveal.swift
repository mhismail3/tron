import SwiftUI

/// Presentation-only token admission for text that is already authoritative in
/// the installed transcript. It deliberately keeps every token in layout and
/// changes only glyph opacity, so revealing text cannot move the scroll viewport.
enum ChatStreamingTextRevealPolicy {
    /// The slowest (and low-backlog) spacing between word starts.
    static let wordIntervalMilliseconds = 55.0
    /// The fastest spacing: one 120 Hz display frame. Several words start in
    /// one tick when the spacing is shorter than the tick.
    static let minimumWordIntervalMilliseconds = 8.0
    /// Each admitted word should start within this long of its arrival: one
    /// Gateway progress window (150 ms) plus slack.
    static let drainHorizonMilliseconds = 180.0
    static let fadeMilliseconds = 220
    /// Fade frames are refreshed at least this often while a word fades.
    static let fadeTickMilliseconds = 33.0
    /// Reveal ticks never run faster than one 60 Hz frame.
    static let minimumTickMilliseconds = 16.0
    /// Safety valve for real stalls only: a backlog that the fastest spacing
    /// cannot drain in about a second, or a word that already waited that
    /// long, is shown at once so the UI never lags the authoritative stream.
    static let maximumAnimatedBacklog = Int(1_000 / minimumWordIntervalMilliseconds)
    static let maximumPendingWaitMilliseconds = 1_000.0
    /// Large streaming bodies render authoritatively without per-word
    /// reconstruction. The transcript remains current while avoiding O(message)
    /// allocation on every reveal tick.
    static let maximumAnimatedUTF16Length = 16_384

    struct Admission {
        /// Show every pending word at once (safety valve).
        var catchUp = false
        /// Scheduled start times of the leading pending words, in order.
        var startTimes: [Double] = []
        /// The scheduled start of the most recent word after this admission.
        var clock: Double?
        /// When the next still-pending word becomes due.
        var nextStart: Double?
    }

    /// Spacing for the next word start: the slowest that still starts every
    /// pending word within `drainHorizonMilliseconds` of its arrival. When all
    /// pending words arrived together this is `drainHorizon / pendingWords`;
    /// it is exactly `wordIntervalMilliseconds` at a backlog of three or fewer.
    static func wordInterval(now: Double, pendingArrivals: ArraySlice<Double>) -> Double {
        var interval = wordIntervalMilliseconds
        for (offset, arrival) in pendingArrivals.enumerated() {
            interval = min(interval, (arrival + drainHorizonMilliseconds - now) / Double(offset + 1))
        }
        return max(minimumWordIntervalMilliseconds, interval)
    }

    /// Decides which pending words start at `now` (all times in milliseconds
    /// on one monotonic origin). Pacing depends only on elapsed time since the
    /// last scheduled start and on pending arrivals, never on how often the
    /// caller is invoked, so a new stream frame neither grants an extra word
    /// nor delays the next one. `pendingArrivals` is in reveal order.
    static func admission(now: Double, clock: Double?, pendingArrivals: [Double]) -> Admission {
        guard let oldest = pendingArrivals.first else { return Admission(clock: clock) }
        if pendingArrivals.count > maximumAnimatedBacklog
            || now - oldest > maximumPendingWaitMilliseconds {
            return Admission(catchUp: true)
        }
        var remaining = pendingArrivals[...]
        var interval = wordInterval(now: now, pendingArrivals: remaining)
        // Credit covers at most one tick, so an idle stream or a late tick
        // never releases a burst of words that should have started earlier.
        var clock = max(clock ?? -.infinity, now - max(interval, fadeTickMilliseconds))
        var startTimes: [Double] = []
        while let arrival = remaining.first, clock + interval <= now {
            clock = max(clock + interval, arrival)
            startTimes.append(clock)
            remaining = remaining.dropFirst()
            interval = wordInterval(now: now, pendingArrivals: remaining)
        }
        return Admission(
            startTimes: startTimes,
            clock: clock,
            nextStart: remaining.isEmpty ? nil : clock + interval
        )
    }

    /// How long the reveal loop sleeps before its next tick.
    static func tickMilliseconds(now: Double, nextStart: Double?) -> Double {
        guard let nextStart else { return fadeTickMilliseconds }
        return min(fadeTickMilliseconds, max(minimumTickMilliseconds, nextStart - now))
    }

    static func permitsAnimation(renderedUTF16Length: Int) -> Bool {
        renderedUTF16Length >= 0 && renderedUTF16Length <= maximumAnimatedUTF16Length
    }

    static func shouldAnimate(
        streaming: Bool,
        reduceMotion: Bool,
        surfaceActive: Bool
    ) -> Bool {
        streaming && !reduceMotion && surfaceActive
    }

    static func opacity(elapsedMilliseconds: Int, fadeMilliseconds: Int = Self.fadeMilliseconds) -> Double {
        guard elapsedMilliseconds > 0 else { return 0 }
        guard fadeMilliseconds > 0 else { return 1 }
        return min(1, Double(elapsedMilliseconds) / Double(fadeMilliseconds))
    }
}

enum ChatThinkingTraceLayoutPolicy {
    static let maximumLines = 4
    static let fallbackLineHeight: CGFloat = 16

    static func isOverflowing(contentHeight: CGFloat, maximumHeight: CGFloat) -> Bool {
        contentHeight > 0 && maximumHeight > 0 && contentHeight > maximumHeight + 0.5
    }

    static func viewportHeight(
        contentHeight: CGFloat,
        maximumHeight: CGFloat,
        fallbackLineHeight: CGFloat = Self.fallbackLineHeight
    ) -> CGFloat {
        let fallback = max(1, fallbackLineHeight)
        guard maximumHeight > 0 else { return min(max(contentHeight, fallback), fallback) }
        guard contentHeight > 0 else { return min(maximumHeight, fallback) }
        return min(contentHeight, maximumHeight)
    }

    /// Estimates the bounded trace viewport until TextKit has supplied its
    /// first measurement. A zero-height preference is not evidence that the
    /// trace has no content; using the normal fallback for every admitted line
    /// can create a one-frame height flash when the hidden probe reports wraps.
    static func initialViewportHeight(
        lineCount: Int = 1,
        fallbackLineHeight: CGFloat = Self.fallbackLineHeight
    ) -> CGFloat {
        let boundedLines = min(max(lineCount, 1), maximumLines)
        return max(1, fallbackLineHeight) * CGFloat(boundedLines)
    }

    static func tailOffset(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    static func showsEarlierContent(contentHeight: CGFloat, maximumHeight: CGFloat) -> Bool {
        isOverflowing(contentHeight: contentHeight, maximumHeight: maximumHeight)
    }

    static func admitsMeasurement(current: CGFloat, candidate: CGFloat) -> Bool {
        candidate.isFinite && candidate > 0 && abs(candidate - current) > 0.5
    }
}

/// Reveal pacing bookkeeping that the body never reads: when each pending word
/// was admitted and the scheduled start of the most recent word. Kept outside
/// view state so updating it costs no body evaluation.
private final class ChatStreamingTextRevealSchedule {
    var clock: Double?
    private var arrivals: [String: Double] = [:]

    /// Arrival times of `pending` in order; a word seen for the first time
    /// arrives at `now`.
    func arrivals(of pending: [ChatStreamingTextToken], now: Double) -> [Double] {
        pending.map { token in
            if let arrival = arrivals[token.id] { return arrival }
            arrivals[token.id] = now
            return now
        }
    }

    func started(_ id: String) {
        arrivals.removeValue(forKey: id)
    }

    func retain(_ ids: Set<String>) {
        if arrivals.keys.contains(where: { !ids.contains($0) }) {
            arrivals = arrivals.filter { ids.contains($0.key) }
        }
    }

    func reset() {
        clock = nil
        if !arrivals.isEmpty { arrivals.removeAll() }
    }
}

struct ChatStreamingTextToken: Identifiable {
    let id: String
    let value: AttributedString
    let isWord: Bool
}

/// One mounted inline owns one bounded tokenization cache. Animation ticks read
/// immutable slices instead of repeatedly splitting and rebuilding token IDs,
/// and the rendered text is concatenated once per token revision rather than
/// on every body evaluation.
private final class ChatStreamingTextTokenCache {
    private var source: String?
    private var hasPreparedAttributes = false
    private var identity: String?
    private var value: [ChatStreamingTextToken] = []
    private var opaqueText: AttributedString?
    private var revealedPrefix = AttributedString()
    private var revealedPrefixCount = 0
    private var revealedPrefixEpoch = 0
    /// Advanced by every reconciliation, the only place revealed IDs can be
    /// removed. Between advances they only grow, so a memoized fully revealed
    /// prefix stays exact and a reveal tick appends only its pending tail.
    var revealedEpoch = 0

    func resolve(
        inline: MarkdownPresentation.Inline,
        identity: String,
        build: () -> [ChatStreamingTextToken]
    ) -> [ChatStreamingTextToken] {
        let hasPreparedAttributes = inline.attributedString != nil
        if source != inline.source
            || self.hasPreparedAttributes != hasPreparedAttributes
            || self.identity != identity {
            source = inline.source
            self.hasPreparedAttributes = hasPreparedAttributes
            self.identity = identity
            value = build()
            opaqueText = nil
            revealedPrefix = AttributedString()
            revealedPrefixCount = 0
            revealedPrefixEpoch = revealedEpoch
        }
        return value
    }

    /// Every token at full opacity: the rendered text whenever no fade applies.
    func resolvedOpaqueText() -> AttributedString {
        if let opaqueText { return opaqueText }
        var result = AttributedString()
        for token in value { result += token.value }
        opaqueText = result
        return result
    }

    /// The longest leading run of tokens that render unmodified because each
    /// is whitespace-only or already revealed, and its token count.
    func resolvedRevealedPrefix(revealedIDs: Set<String>) -> (text: AttributedString, count: Int) {
        if revealedPrefixEpoch != revealedEpoch {
            revealedPrefixEpoch = revealedEpoch
            revealedPrefix = AttributedString()
            revealedPrefixCount = 0
        }
        while revealedPrefixCount < value.count {
            let token = value[revealedPrefixCount]
            guard !token.isWord || revealedIDs.contains(token.id) else { break }
            revealedPrefix += token.value
            revealedPrefixCount += 1
        }
        return (revealedPrefix, revealedPrefixCount)
    }
}

/// Reveal bookkeeping recorded while text is not streaming, applied only if
/// the same mounted inline later streams. Settling complete text therefore
/// writes no view state (and costs no second body evaluation), while a later
/// switch to streaming still treats every word settled here as revealed.
private final class ChatStreamingTextSettlement {
    private struct Source {
        let text: String
        let hasPreparedAttributes: Bool
        let identity: String
        let tokens: [ChatStreamingTextToken]
    }

    /// Distinct sources settled while covered accumulate until one is folded
    /// into view state; this bounds that accumulation.
    static let maximumSources = 8

    /// Whether an uncovered settlement replaced the view's revealed IDs.
    private var replacesStoredIDs = false
    private var sources: [Source] = []

    var isEmpty: Bool { sources.isEmpty }
    var isFull: Bool { sources.count >= Self.maximumSources }

    /// Uncovered settlement reveals exactly the settled words; covered
    /// settlement adds them to whatever was revealed before.
    func settle(
        inline: MarkdownPresentation.Inline,
        identity: String,
        tokens: [ChatStreamingTextToken],
        surfaceActive: Bool
    ) {
        let source = Source(
            text: inline.source,
            hasPreparedAttributes: inline.attributedString != nil,
            identity: identity,
            tokens: tokens
        )
        if surfaceActive {
            replacesStoredIDs = true
            sources = [source]
            return
        }
        // The token cache's key: equal keys always carry equal tokens.
        let isKnown = sources.contains { known in
            known.text == source.text
                && known.hasPreparedAttributes == source.hasPreparedAttributes
                && known.identity == source.identity
        }
        if !isKnown { sources.append(source) }
    }

    func revealedIDs(stored: Set<String>) -> Set<String> {
        var result: Set<String> = replacesStoredIDs ? [] : stored
        for source in sources {
            for token in source.tokens where token.isWord { result.insert(token.id) }
        }
        return result
    }

    func reset() {
        replacesStoredIDs = false
        sources.removeAll()
    }
}

/// Reveals newly admitted words without changing the authoritative text,
/// markdown structure, row identity, or measured layout. The view is intended
/// for an already-mounted streaming message/thinking run; it is not a fake
/// transport or a timer that drips content into the transcript.
struct ChatStreamingInlineText: View {
    let inline: MarkdownPresentation.Inline
    let identity: String
    let baseColor: Color
    let streaming: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var revealedIDs: Set<String> = []
    @State private var revealStarts: [String: Date] = [:]
    @State private var animationTick = 0
    @State private var hasAdmittedInitialContent = false
    @State private var tokenCache = ChatStreamingTextTokenCache()
    @State private var settlement = ChatStreamingTextSettlement()
    @State private var schedule = ChatStreamingTextRevealSchedule()

    var body: some View {
        let _ = animationTick
        let tokens = tokenCache.resolve(inline: inline, identity: identity) {
            let value = inline.attributedString ?? AttributedString(inline.source)
            guard ChatStreamingTextRevealPolicy.permitsAnimation(
                renderedUTF16Length: inline.source.utf16.count
            ) else {
                return [ChatStreamingTextToken(
                    id: "\(identity):authoritative",
                    value: value,
                    isWord: false
                )]
            }
            return Self.tokens(in: value, identity: identity)
        }
        let taskKey = TaskKey(
            source: inline.source,
            hasPreparedAttributes: inline.attributedString != nil,
            identity: identity,
            streaming: streaming,
            reduceMotion: reduceMotion,
            surfaceActive: presentationActivity.allowsContinuousAnimation
        )
        return renderedText(tokens: tokens)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(inline.source)
            // The task is presentation bookkeeping only. The full source is
            // already rendered in layout before this task admits any fade.
            .task(id: taskKey) { await reconcile(tokens: tokens) }
    }

    private func renderedText(tokens: [ChatStreamingTextToken]) -> Text {
        guard ChatStreamingTextRevealPolicy.shouldAnimate(
            streaming: streaming,
            reduceMotion: reduceMotion,
            surfaceActive: presentationActivity.allowsContinuousAnimation
        ) else { return Text(tokenCache.resolvedOpaqueText()) }
        // A settlement recorded before streaming began has not been folded
        // into view state until the reconcile task runs; read through it.
        let settlementPending = !settlement.isEmpty
        // The first body evaluation happens before the bookkeeping task. Keep
        // the authoritative initial source visible during that handoff; a
        // missing reveal start is only hidden for tokens admitted later.
        guard hasAdmittedInitialContent || settlementPending else {
            return Text(tokenCache.resolvedOpaqueText())
        }
        let revealed = settlementPending ? settlement.revealedIDs(stored: revealedIDs) : revealedIDs
        let prefix = settlementPending
            ? (text: AttributedString(), count: 0)
            : tokenCache.resolvedRevealedPrefix(revealedIDs: revealed)
        var result = prefix.text
        let now = Date.now
        for token in tokens[prefix.count...] {
            var value = token.value
            guard token.isWord else {
                result += value
                continue
            }
            let opacity = tokenOpacity(token.id, revealed: revealed, now: now)
            if opacity < 0.999 {
                // Markdown presentation intents and links remain attached to
                // the slice. Only the temporary foreground alpha is changed.
                value.foregroundColor = baseColor.opacity(opacity)
            }
            result += value
        }
        return Text(result)
    }

    private func tokenOpacity(_ id: String, revealed: Set<String>, now: Date) -> Double {
        if revealed.contains(id) { return 1 }
        guard let started = revealStarts[id] else { return 0 }
        return ChatStreamingTextRevealPolicy.opacity(
            elapsedMilliseconds: max(0, Int(now.timeIntervalSince(started) * 1_000))
        )
    }

    @MainActor
    private func reconcile(tokens: [ChatStreamingTextToken]) async {
        tokenCache.revealedEpoch &+= 1
        guard streaming else {
            // Complete text is fully visible whatever this bookkeeping holds.
            // Record it without writing view state; a later switch to
            // streaming folds it in below before any fade starts.
            if !revealStarts.isEmpty { revealStarts.removeAll() }
            schedule.reset()
            if settlement.isFull { foldSettlement() }
            settlement.settle(
                inline: inline,
                identity: identity,
                tokens: tokens,
                surfaceActive: presentationActivity.allowsContinuousAnimation
            )
            return
        }
        foldSettlement()
        let currentIDs = Set(tokens.lazy.filter(\.isWord).map(\.id))
        guard presentationActivity.allowsContinuousAnimation else {
            // Covered content must never replay a reveal backlog when it is
            // uncovered; its authoritative text remains immediately visible.
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            schedule.reset()
            hasAdmittedInitialContent = true
            return
        }
        revealedIDs.formIntersection(currentIDs)
        revealStarts = revealStarts.filter { currentIDs.contains($0.key) }
        schedule.retain(currentIDs)

        guard !reduceMotion else {
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            schedule.reset()
            hasAdmittedInitialContent = true
            return
        }

        if !hasAdmittedInitialContent {
            // The first mounted frame is already authoritative and measured.
            // Never render it transparent while the bookkeeping task starts:
            // that produces the one-frame flash most noticeable in thinking
            // traces and large assistant responses. Only tokens admitted by a
            // later stream update receive the presentation fade.
            hasAdmittedInitialContent = true
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            schedule.reset()
            return
        }

        // Every stream frame restarts this task. Pacing lives in `schedule`
        // and the pure policy, so the restart itself changes nothing.
        while !Task.isCancelled {
            let now = Date.now
            let nowMilliseconds = now.timeIntervalSinceReferenceDate * 1_000
            let pending = tokens.filter {
                $0.isWord && !revealedIDs.contains($0.id) && revealStarts[$0.id] == nil
            }
            let admission = ChatStreamingTextRevealPolicy.admission(
                now: nowMilliseconds,
                clock: schedule.clock,
                pendingArrivals: schedule.arrivals(of: pending, now: nowMilliseconds)
            )
            if admission.catchUp {
                // A stalled renderer/network update must never make the native
                // UI lag behind the authoritative stream by an unbounded queue.
                revealedIDs.formUnion(currentIDs)
                revealStarts.removeAll()
                schedule.reset()
                return
            }
            schedule.clock = admission.clock
            for (token, start) in zip(pending, admission.startTimes) {
                revealStarts[token.id] = Date(timeIntervalSinceReferenceDate: start / 1_000)
                schedule.started(token.id)
            }

            let completedIDs = revealStarts.compactMap { id, started in
                now.timeIntervalSince(started) * 1_000 >= Double(ChatStreamingTextRevealPolicy.fadeMilliseconds)
                    ? id
                    : nil
            }
            for id in completedIDs {
                revealedIDs.insert(id)
                revealStarts.removeValue(forKey: id)
            }
            animationTick &+= 1

            guard admission.nextStart != nil || !revealStarts.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(ChatStreamingTextRevealPolicy.tickMilliseconds(
                now: nowMilliseconds,
                nextStart: admission.nextStart
            )))
        }
    }

    /// Applies a settlement recorded while not streaming to view state, as
    /// the settling reconciliation itself would have written it.
    @MainActor
    private func foldSettlement() {
        guard !settlement.isEmpty else { return }
        revealedIDs = settlement.revealedIDs(stored: revealedIDs)
        settlement.reset()
        hasAdmittedInitialContent = true
    }

    private struct TaskKey: Equatable {
        let source: String
        let hasPreparedAttributes: Bool
        let identity: String
        let streaming: Bool
        let reduceMotion: Bool
        let surfaceActive: Bool
    }

    /// Splits `value` into word tokens (a word plus its trailing whitespace,
    /// with any leading whitespace) and whitespace-only runs whose
    /// concatenation is exactly `value`.
    static func tokens(
        in value: AttributedString,
        identity: String
    ) -> [ChatStreamingTextToken] {
        var result: [ChatStreamingTextToken] = []
        var cursor = value.startIndex
        var ordinal = 0

        runs: while cursor < value.endIndex {
            let runStart = cursor
            var wordStart: AttributedString.Index?
            while cursor < value.endIndex {
                let next = value.index(afterCharacter: cursor)
                let character = value.characters[cursor]
                if !character.isWhitespace {
                    wordStart = wordStart ?? cursor
                } else if wordStart != nil {
                    cursor = next
                    while cursor < value.endIndex, value.characters[cursor].isWhitespace {
                        cursor = value.index(afterCharacter: cursor)
                    }
                    result.append(ChatStreamingTextToken(
                        id: "\(identity):word:\(ordinal)",
                        value: AttributedString(value[runStart..<cursor]),
                        isWord: true
                    ))
                    ordinal += 1
                    // The word is emitted with its trailing whitespace; the
                    // end-of-text check below must not append it again.
                    continue runs
                }
                cursor = next
            }

            if cursor >= value.endIndex, wordStart != nil {
                result.append(ChatStreamingTextToken(
                    id: "\(identity):word:\(ordinal)",
                    value: AttributedString(value[runStart..<value.endIndex]),
                    isWord: true
                ))
                ordinal += 1
            } else if wordStart == nil, runStart < cursor {
                result.append(ChatStreamingTextToken(
                    id: "\(identity):space:\(ordinal)",
                    value: AttributedString(value[runStart..<cursor]),
                    isWord: false
                ))
                ordinal += 1
            }
        }
        return result
    }
}

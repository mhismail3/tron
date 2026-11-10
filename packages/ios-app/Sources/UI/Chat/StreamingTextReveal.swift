import SwiftUI

enum ChatStreamingTextRevealPolicy {
    static let wordIntervalMilliseconds = 55.0
    static let minimumWordIntervalMilliseconds = 8.0
    static let drainHorizonMilliseconds = 180.0
    static let fadeMilliseconds = 220
    static let fadeTickMilliseconds = 33.0
    static let minimumTickMilliseconds = 16.0
    static let maximumAnimatedBacklog = Int(1_000 / minimumWordIntervalMilliseconds)
    static let maximumPendingWaitMilliseconds = 1_000.0
    static let maximumAnimatedUTF16Length = 16_384

    struct Admission {
        var catchUp = false
        var startTimes: [Double] = []
        var clock: Double?
        var nextStart: Double?
    }

    static func wordInterval(now: Double, pendingArrivals: ArraySlice<Double>) -> Double {
        var interval = wordIntervalMilliseconds
        for (offset, arrival) in pendingArrivals.enumerated() {
            interval = min(interval, (arrival + drainHorizonMilliseconds - now) / Double(offset + 1))
        }
        return max(minimumWordIntervalMilliseconds, interval)
    }

    static func admission(now: Double, clock: Double?, pendingArrivals: [Double]) -> Admission {
        guard let oldest = pendingArrivals.first else { return Admission(clock: clock) }
        if pendingArrivals.count > maximumAnimatedBacklog
            || now - oldest > maximumPendingWaitMilliseconds {
            return Admission(catchUp: true)
        }
        var remaining = pendingArrivals[...]
        var interval = wordInterval(now: now, pendingArrivals: remaining)
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

private final class ChatStreamingTextRevealSchedule {
    var clock: Double?
    private var arrivals: [String: Double] = [:]

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

private final class ChatStreamingTextTokenCache {
    private var source: String?
    private var hasPreparedAttributes = false
    private var identity: String?
    private var value: [ChatStreamingTextToken] = []
    private var opaqueText: AttributedString?
    private var revealedPrefix = AttributedString()
    private var revealedPrefixCount = 0
    private var revealedPrefixEpoch = 0
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

    func resolvedOpaqueText() -> AttributedString {
        if let opaqueText { return opaqueText }
        var result = AttributedString()
        for token in value { result += token.value }
        opaqueText = result
        return result
    }

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

private final class ChatStreamingTextSettlement {
    private struct Source {
        let text: String
        let hasPreparedAttributes: Bool
        let identity: String
        let tokens: [ChatStreamingTextToken]
    }

    static let maximumSources = 8

    private var replacesStoredIDs = false
    private var sources: [Source] = []

    var isEmpty: Bool { sources.isEmpty }
    var isFull: Bool { sources.count >= Self.maximumSources }

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
            .task(id: taskKey) { await reconcile(tokens: tokens) }
    }

    private func renderedText(tokens: [ChatStreamingTextToken]) -> Text {
        guard ChatStreamingTextRevealPolicy.shouldAnimate(
            streaming: streaming,
            reduceMotion: reduceMotion,
            surfaceActive: presentationActivity.allowsContinuousAnimation
        ) else { return Text(tokenCache.resolvedOpaqueText()) }
        let settlementPending = !settlement.isEmpty
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
            hasAdmittedInitialContent = true
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            schedule.reset()
            return
        }

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

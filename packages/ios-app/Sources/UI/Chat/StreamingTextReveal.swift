import SwiftUI

/// Presentation-only token admission for text that is already authoritative in
/// the installed transcript. It deliberately keeps every token in layout and
/// changes only glyph opacity, so revealing text cannot move the scroll viewport.
enum ChatStreamingTextRevealPolicy {
    static let wordIntervalMilliseconds = 55
    static let fadeMilliseconds = 220
    static let maximumAnimatedBacklog = 18
    static let maximumInitialAnimatedTokens = 12

    static func shouldCatchUp(
        pendingTokenCount: Int,
        initialTokenCount: Int? = nil
    ) -> Bool {
        if pendingTokenCount > maximumAnimatedBacklog { return true }
        if let initialTokenCount, initialTokenCount > maximumInitialAnimatedTokens { return true }
        return false
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
}

private struct ChatStreamingTextToken: Identifiable {
    let id: String
    let value: AttributedString
    let isWord: Bool
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
    @State private var revealedIDs: Set<String> = []
    @State private var revealStarts: [String: Date] = [:]
    @State private var animationTick = 0
    @State private var hasAdmittedInitialContent = false

    private var attributed: AttributedString {
        inline.attributedString ?? AttributedString(inline.source)
    }

    private var tokens: [ChatStreamingTextToken] {
        Self.tokens(in: attributed, identity: identity)
    }

    private var taskKey: TaskKey {
        TaskKey(
            tokenIDs: tokens.map(\.id),
            streaming: streaming,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        let _ = animationTick
        return renderedText
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(inline.source)
            // The task is presentation bookkeeping only. The full source is
            // already rendered in layout before this task admits any fade.
            .task(id: taskKey) { await reconcile() }
    }

    private var renderedText: Text {
        var result = AttributedString()
        let now = Date.now
        for token in tokens {
            var value = token.value
            guard token.isWord else {
                result += value
                continue
            }
            let opacity = tokenOpacity(token.id, now: now)
            if opacity < 0.999 {
                // Markdown presentation intents and links remain attached to
                // the slice. Only the temporary foreground alpha is changed.
                value.foregroundColor = baseColor.opacity(opacity)
            }
            result += value
        }
        return Text(result)
    }

    private func tokenOpacity(_ id: String, now: Date) -> Double {
        guard streaming, !reduceMotion else { return 1 }
        // The first body evaluation happens before the bookkeeping task. Keep
        // the authoritative initial source visible during that handoff; a
        // missing reveal start is only hidden for tokens admitted later.
        guard hasAdmittedInitialContent else { return 1 }
        if revealedIDs.contains(id) { return 1 }
        guard let started = revealStarts[id] else { return 0 }
        return ChatStreamingTextRevealPolicy.opacity(
            elapsedMilliseconds: max(0, Int(now.timeIntervalSince(started) * 1_000))
        )
    }

    @MainActor
    private func reconcile() async {
        let currentIDs = Set(tokens.filter(\.isWord).map(\.id))
        revealedIDs.formIntersection(currentIDs)
        revealStarts = revealStarts.filter { currentIDs.contains($0.key) }

        guard streaming, !reduceMotion else {
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            hasAdmittedInitialContent = true
            return
        }

        let pendingIDs = tokens.filter { $0.isWord && !revealedIDs.contains($0.id) && revealStarts[$0.id] == nil }
        if !hasAdmittedInitialContent {
            // The first mounted frame is already authoritative and measured.
            // Never render it transparent while the bookkeeping task starts:
            // that produces the one-frame flash most noticeable in thinking
            // traces and large assistant responses. Only tokens admitted by a
            // later stream update receive the presentation fade.
            hasAdmittedInitialContent = true
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            return
        } else if ChatStreamingTextRevealPolicy.shouldCatchUp(pendingTokenCount: pendingIDs.count) {
            // A slow renderer/network update must never make the native UI lag
            // behind the authoritative stream by an unbounded word queue.
            revealedIDs.formUnion(currentIDs)
            revealStarts.removeAll()
            return
        }

        while !Task.isCancelled {
            let pending = tokens.filter { $0.isWord && !revealedIDs.contains($0.id) && revealStarts[$0.id] == nil }
            let startedNewToken: Bool
            if let next = pending.first {
                revealStarts[next.id] = .now
                startedNewToken = true
            } else {
                startedNewToken = false
            }

            let now = Date.now
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

            let stillPending = tokens.contains { $0.isWord && !revealedIDs.contains($0.id) }
            guard stillPending || !revealStarts.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(
                startedNewToken
                    ? ChatStreamingTextRevealPolicy.wordIntervalMilliseconds
                    : 33
            ))
        }
    }

    private struct TaskKey: Equatable {
        let tokenIDs: [String]
        let streaming: Bool
        let reduceMotion: Bool
    }

    private static func tokens(
        in value: AttributedString,
        identity: String
    ) -> [ChatStreamingTextToken] {
        var result: [ChatStreamingTextToken] = []
        var cursor = value.startIndex
        var ordinal = 0

        while cursor < value.endIndex {
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
                    break
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

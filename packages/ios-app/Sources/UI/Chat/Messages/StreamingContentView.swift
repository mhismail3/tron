import SwiftUI

// MARK: - Streaming Content View

/// Optimized for efficient rendering during rapid text updates
struct StreamingContentView: View {
    let text: String
    @Environment(\.textSelectionDisabled) private var textSelectionDisabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let characterCount = text.count

        // Keep one stable Text identity from the placeholder through the first
        // delta. Each displayed prefix stays semantic; only its live drawing fades.
        Text(text.isEmpty ? " " : text)
            .font(TronTypography.messageBody)
            .foregroundStyle(.assistantMessageText)
            .lineSpacing(4)
            .selectableText(!textSelectionDisabled)
            .textRenderer(StreamingTextRevealRenderer(
                revealedCharacterCount: Double(characterCount),
                targetCharacterCount: characterCount,
                reduceMotion: reduceMotion
            ))
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: StreamingTextRevealPolicy.duration),
                value: characterCount
            )
            .padding(.top, 4)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Draw-time policy for a soft streaming edge without a second text buffer.
///
/// SwiftUI interpolates `revealedCharacterCount` from the previous append to the
/// current one. Only the bounded trailing source-character groups in the final
/// visual line use custom opacity; earlier lines use native line drawing and the
/// displayed `Text` remains available to selection and accessibility.
enum StreamingTextRevealPolicy {
    static let duration = 0.07
    static let minimumOpacity = 0.32
    static let maxAnimatedCharacters = 24

    static func opacity(
        forCharacterAt characterIndex: Int,
        lineCharacterCount: Int,
        targetCharacterCount: Int,
        revealedCharacterCount: Double,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion, lineCharacterCount > 0 else { return 1 }

        let outstandingCharacters = max(
            0,
            Double(targetCharacterCount) - revealedCharacterCount
        )
        guard outstandingCharacters > 0 else { return 1 }

        let animatedTail = min(
            outstandingCharacters,
            Double(maxAnimatedCharacters),
            Double(lineCharacterCount)
        )
        let revealBoundary = Double(lineCharacterCount) - animatedTail
        let characterProgress = min(
            max(revealBoundary - Double(characterIndex), 0),
            1
        )
        return minimumOpacity + ((1 - minimumOpacity) * characterProgress)
    }
}

private struct StreamingTextRevealRenderer: TextRenderer {
    var revealedCharacterCount: Double
    let targetCharacterCount: Int
    let reduceMotion: Bool

    var animatableData: Double {
        get { revealedCharacterCount }
        set { revealedCharacterCount = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard let liveLine = layout.last else { return }

        for line in layout.dropLast() {
            context.draw(line)
        }

        guard !reduceMotion, revealedCharacterCount < Double(targetCharacterCount) else {
            context.draw(liveLine)
            return
        }

        let orderedCharacterIndices = Array(Set(
            liveLine.flatMap(\.characterIndices)
        )).sorted()
        let characterOffsets = Dictionary(
            uniqueKeysWithValues: orderedCharacterIndices.enumerated().map {
                ($0.element, $0.offset)
            }
        )

        for run in liveLine {
            let indices = run.characterIndices
            guard indices.count == run.count else {
                context.draw(run)
                continue
            }

            var opaqueStart = run.startIndex
            var groupStart = run.startIndex
            while groupStart < run.endIndex {
                let sourceIndex = indices[groupStart - run.startIndex]
                var groupEnd = groupStart + 1
                while groupEnd < run.endIndex,
                      indices[groupEnd - run.startIndex] == sourceIndex {
                    groupEnd += 1
                }

                let opacity = StreamingTextRevealPolicy.opacity(
                    forCharacterAt: characterOffsets[sourceIndex] ?? 0,
                    lineCharacterCount: orderedCharacterIndices.count,
                    targetCharacterCount: targetCharacterCount,
                    revealedCharacterCount: revealedCharacterCount,
                    reduceMotion: reduceMotion
                )
                if opacity < 1 {
                    if opaqueStart < groupStart {
                        context.draw(run[opaqueStart ..< groupStart])
                    }

                    var characterContext = context
                    characterContext.opacity *= opacity
                    characterContext.draw(run[groupStart ..< groupEnd])
                    opaqueStart = groupEnd
                }
                groupStart = groupEnd
            }

            if opaqueStart < run.endIndex {
                context.draw(run[opaqueStart ..< run.endIndex])
            }
        }
    }
}

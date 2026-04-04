import SwiftUI

/// Text view that animates changes with a typewriter effect:
/// deletes the old text character by character, then types the new text.
///
/// Changes during the settle window (first 500ms after appear) snap
/// instantly so async-loaded titles don't trigger a stale animation.
@available(iOS 26.0, *)
struct TypewriterText: View {
    let text: String
    let font: Font
    let color: Color
    var characterDelay: Duration = .milliseconds(30)

    @State private var displayedText: String
    @State private var animationTask: Task<Void, Never>?
    /// True once the settle window has elapsed and animations are allowed.
    @State private var hasSettled = false

    init(text: String, font: Font, color: Color, characterDelay: Duration = .milliseconds(30)) {
        self.text = text
        self.font = font
        self.color = color
        self.characterDelay = characterDelay
        self._displayedText = State(initialValue: text)
        logger.info("[TW] init text='\(text)'", category: .ui)
    }

    var body: some View {
        let _ = logger.info("[TW] body text='\(text)' displayed='\(displayedText)' settled=\(hasSettled)", category: .ui)
        Text(displayedText)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: !hasSettled, vertical: false)
            .onChange(of: text) { oldValue, newValue in
                logger.info("[TW] onChange old='\(oldValue)' new='\(newValue)' settled=\(hasSettled)", category: .ui)
                if hasSettled {
                    animate(to: newValue)
                } else {
                    logger.info("[TW] snap (not settled) to='\(newValue)'", category: .ui)
                    displayedText = newValue
                }
            }
            .task {
                logger.info("[TW] settle task started", category: .ui)
                try? await Task.sleep(for: .milliseconds(350))
                hasSettled = true
                logger.info("[TW] settled=true displayed='\(displayedText)'", category: .ui)
            }
    }

    private func animate(to newText: String) {
        logger.info("[TW] animate(to: '\(newText)') current='\(displayedText)'", category: .ui)
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            // Phase 1: Delete current text character by character
            var deleteCount = 0
            while !displayedText.isEmpty {
                try? await Task.sleep(for: characterDelay)
                guard !Task.isCancelled else {
                    logger.info("[TW] CANCELLED during delete after \(deleteCount) chars", category: .ui)
                    displayedText = newText
                    return
                }
                displayedText = String(displayedText.dropLast())
                deleteCount += 1
            }
            logger.info("[TW] delete done (\(deleteCount) chars), typing \(newText.count) chars", category: .ui)

            // Phase 2: Type new text character by character.
            // The first character is appended WITHOUT sleeping so that
            // displayedText transitions "" → "X" atomically (no yield).
            // This prevents SwiftUI toolbar layout from collapsing to
            // zero width on the empty string and never re-expanding.
            for (index, char) in newText.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: characterDelay)
                    guard !Task.isCancelled else {
                        logger.info("[TW] CANCELLED during type after \(index) chars", category: .ui)
                        displayedText = newText
                        return
                    }
                }
                displayedText.append(char)
            }
            logger.info("[TW] animation complete: '\(displayedText)'", category: .ui)
        }
    }
}

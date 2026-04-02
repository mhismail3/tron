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
    }

    var body: some View {
        Text(displayedText)
            .font(font)
            .foregroundStyle(color)
            .onChange(of: text) { _, newValue in
                if hasSettled {
                    animate(to: newValue)
                } else {
                    displayedText = newValue
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                hasSettled = true
            }
    }

    private func animate(to newText: String) {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            // Phase 1: Delete current text character by character
            while !displayedText.isEmpty {
                try? await Task.sleep(for: characterDelay)
                guard !Task.isCancelled else { return }
                displayedText = String(displayedText.dropLast())
            }

            // Phase 2: Type new text character by character
            for char in newText {
                try? await Task.sleep(for: characterDelay)
                guard !Task.isCancelled else {
                    displayedText = newText
                    return
                }
                displayedText.append(char)
            }
        }
    }
}

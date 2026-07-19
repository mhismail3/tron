import SwiftUI

/// Text view that animates changes with a typewriter effect:
/// deletes the old text character by character, then types the new text.
///
/// Changes during the settle window (first 350ms after appear) snap
/// instantly so async-loaded titles don't trigger a stale animation.
struct TypewriterText: View {
    let text: String
    let font: Font
    let color: Color
    var characterDelay: Duration = .milliseconds(30)

    @State private var animationState: TypewriterAnimationState
    /// True once the settle window has elapsed and animations are allowed.
    @State private var hasSettled = false

    init(text: String, font: Font, color: Color, characterDelay: Duration = .milliseconds(30)) {
        self.text = text
        self.font = font
        self.color = color
        self.characterDelay = characterDelay
        self._animationState = State(
            initialValue: TypewriterAnimationState(text: text, characterDelay: characterDelay)
        )
    }

    var body: some View {
        Text(animationState.displayedText)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: !hasSettled, vertical: false)
            .onChange(of: text) { _, newValue in
                if hasSettled {
                    animationState.characterDelay = characterDelay
                    animationState.animate(to: newValue)
                } else {
                    animationState.snap(to: newValue)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                hasSettled = true
            }
    }
}

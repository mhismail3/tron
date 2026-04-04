import SwiftUI

/// Testable animation state for TypewriterText.
///
/// Manages character-by-character delete-then-type animation.
/// Cancellation at any phase recovers to the target text.
@Observable
@MainActor
final class TypewriterAnimationState {
    private(set) var displayedText: String
    /// True while a delete-then-type animation is in progress.
    /// Used by TypewriterText to keep `fixedSize(horizontal: true)` during
    /// animation, preventing the toolbar from collapsing to zero width
    /// when `displayedText` is temporarily empty.
    private(set) var isAnimating = false
    var characterDelay: Duration
    private var animationTask: Task<Void, Never>?

    init(text: String, characterDelay: Duration = .milliseconds(30)) {
        self.displayedText = text
        self.characterDelay = characterDelay
    }

    /// Set text immediately, cancelling any running animation.
    func snap(to text: String) {
        animationTask?.cancel()
        isAnimating = false
        displayedText = text
    }

    /// Animate from current text to new text: delete character-by-character, then type.
    func animate(to newText: String) {
        animationTask?.cancel()
        isAnimating = true
        animationTask = Task { @MainActor in
            // Phase 1: Delete current text character by character
            while !displayedText.isEmpty {
                try? await Task.sleep(for: characterDelay)
                guard !Task.isCancelled else {
                    displayedText = newText
                    isAnimating = false
                    return
                }
                displayedText = String(displayedText.dropLast())
            }

            // Phase 2: Type new text character by character.
            // First char appended without sleeping so "" → "X" is atomic
            // (prevents SwiftUI toolbar layout collapse on empty string).
            for (index, char) in newText.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: characterDelay)
                    guard !Task.isCancelled else {
                        displayedText = newText
                        isAnimating = false
                        return
                    }
                }
                displayedText.append(char)
            }
            isAnimating = false
        }
    }

    /// Wait for the current animation to complete. For testing.
    func waitForCompletion() async {
        await animationTask?.value
    }
}

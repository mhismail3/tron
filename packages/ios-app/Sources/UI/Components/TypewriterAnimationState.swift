import SwiftUI

/// Testable animation state mirroring TypewriterText's logic.
///
/// Manages character-by-character delete-then-type animation.
/// Cancellation at any phase recovers to the target text.
@Observable
@MainActor
final class TypewriterAnimationState {
    private(set) var displayedText: String
    var characterDelay: Duration
    private var animationTask: Task<Void, Never>?

    init(text: String, characterDelay: Duration = .milliseconds(30)) {
        self.displayedText = text
        self.characterDelay = characterDelay
    }

    /// Set text immediately, cancelling any running animation.
    func snap(to text: String) {
        animationTask?.cancel()
        displayedText = text
    }

    /// Animate from current text to new text: delete character-by-character, then type.
    func animate(to newText: String) {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            // Phase 1: Delete current text character by character
            while !displayedText.isEmpty {
                try? await Task.sleep(for: characterDelay)
                guard !Task.isCancelled else {
                    displayedText = newText
                    return
                }
                displayedText = String(displayedText.dropLast())
            }

            // Phase 2: Type new text character by character.
            // First char is appended without sleeping so the "" → "X"
            // transition is atomic. Without this, Text("") in a SwiftUI
            // toolbar causes a permanent layout collapse to zero width.
            for (index, char) in newText.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: characterDelay)
                    guard !Task.isCancelled else {
                        displayedText = newText
                        return
                    }
                }
                displayedText.append(char)
            }
        }
    }

    /// Wait for the current animation to complete. For testing.
    func waitForCompletion() async {
        await animationTask?.value
    }
}

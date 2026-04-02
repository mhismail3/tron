import SwiftUI

/// Text view that animates changes with a typewriter effect:
/// deletes the old text character by character, then types the new text.
@available(iOS 26.0, *)
struct TypewriterText: View {
    let text: String
    let font: Font
    let color: Color
    var characterDelay: Duration = .milliseconds(30)

    @State private var displayedText: String = ""
    @State private var animationTask: Task<Void, Never>?
    @State private var hasAppeared = false

    var body: some View {
        Text(displayedText.isEmpty ? text : displayedText)
            .font(font)
            .foregroundStyle(color)
            .onChange(of: text) { _, newValue in
                if hasAppeared {
                    animate(to: newValue)
                } else {
                    displayedText = newValue
                }
            }
            .onAppear {
                displayedText = text
                hasAppeared = true
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

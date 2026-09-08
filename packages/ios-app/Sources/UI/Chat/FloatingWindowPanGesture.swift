import SwiftUI

/// One native pan lifecycle: cancellation and release never reset a value that
/// contributes to the rendered position. Coordinates come from the same native
/// proposal that fits the window, not a keyboard offset or a cached frame.
struct FloatingWindowPanGesture: UIGestureRecognizerRepresentable {
    enum Space: Hashable { case bounds, window }

    struct Sample {
        let state: UIGestureRecognizer.State
        let location: CGPoint
        let locationInWindow: CGPoint
        let velocity: CGPoint
    }

    let onAction: (Sample) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let converter = context.converter
        onAction(Sample(
            state: recognizer.state,
            location: converter.location(in: .named(Space.bounds)),
            locationInWindow: converter.location(in: .named(Space.window)),
            velocity: converter.velocity(in: .named(Space.bounds)) ?? .zero
        ))
    }
}

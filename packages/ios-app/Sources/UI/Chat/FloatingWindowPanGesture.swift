import SwiftUI

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

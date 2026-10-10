#if HOSTED_TEST
import SwiftUI

/// Native mounted geometry and the production corner/pan callbacks. Scripted
/// pan samples are not touch automation; this is absent from application builds.
final class FloatingDisplayHostedMarker: UIView {
    var move: ((UnitPoint) -> Void)?
    var pan: ((FloatingWindowPanGesture.Sample) -> Void)?
    var dismiss: (() -> Void)?
}

struct FloatingDisplayHostedProbe: UIViewRepresentable {
    let move: (UnitPoint) -> Void
    let pan: (FloatingWindowPanGesture.Sample) -> Void
    let dismiss: () -> Void
    func makeUIView(context: Context) -> FloatingDisplayHostedMarker {
        let view = FloatingDisplayHostedMarker()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: FloatingDisplayHostedMarker, context: Context) {
        view.move = move
        view.pan = pan
        view.dismiss = dismiss
    }
    static func dismantleUIView(_ view: FloatingDisplayHostedMarker, coordinator: ()) {
        view.move = nil
        view.pan = nil
        view.dismiss = nil
    }
}
#endif

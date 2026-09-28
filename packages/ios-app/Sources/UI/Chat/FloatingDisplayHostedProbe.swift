#if HOSTED_TEST
import SwiftUI

/// Native mounted geometry and the production corner/pan callbacks. Scripted
/// pan samples are not touch automation; this is absent from application builds.
final class FloatingDisplayHostedMarker: UIView {
    var move: ((UnitPoint) -> Void)?
    var pan: ((FloatingWindowPanGesture.Sample) -> Void)?
}

struct FloatingDisplayHostedProbe: UIViewRepresentable {
    let move: (UnitPoint) -> Void
    let pan: (FloatingWindowPanGesture.Sample) -> Void
    func makeUIView(context: Context) -> FloatingDisplayHostedMarker {
        let view = FloatingDisplayHostedMarker()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: FloatingDisplayHostedMarker, context: Context) {
        view.move = move
        view.pan = pan
    }
    static func dismantleUIView(_ view: FloatingDisplayHostedMarker, coordinator: ()) {
        view.move = nil
        view.pan = nil
    }
}
#endif

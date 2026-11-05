#if HOSTED_TEST
import SwiftUI
import UIKit

/// Read-only system geometry for the production-scene UI boundary, never shipping UI.
struct HostedNativeViewportProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = NativeViewportProbeView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "hosted-native-viewport"
        view.accessibilityLabel = "Native viewport geometry"
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

private final class NativeViewportProbeView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Allocate the native guide before the tested keyboard/lifecycle events.
        _ = window?.rootViewController?.viewIfLoaded?.keyboardLayoutGuide
    }

    override var accessibilityValue: String? {
        get {
            guard let window, let root = window.rootViewController?.viewIfLoaded,
                  root.window === window else { return nil }
            let bounds = window.bounds
            let guide = root.convert(root.keyboardLayoutGuide.layoutFrame, to: window)
            let safeBottom = window.safeAreaInsets.bottom
            let values = [bounds.minX, bounds.minY, bounds.width, bounds.height,
                          guide.minX, guide.minY, guide.width, guide.height, safeBottom]
            // A partial/floating/out-of-window or unavailable guide is not a
            // bottom viewport inset. Reject it rather than guessing from AX keys.
            guard values.allSatisfy({ $0.isFinite }), bounds.width > 0, bounds.height > 0,
                  safeBottom >= 0, safeBottom < bounds.height,
                  bounds.contains(guide), guide.minX == bounds.minX,
                  guide.maxX == bounds.maxX, guide.maxY == bounds.maxY,
                  guide.height >= safeBottom else { return nil }
            let packet: [String: Any] = [
                "capturedAt": Date().timeIntervalSince1970,
                "window": [bounds.minX, bounds.minY, bounds.width, bounds.height].map(Double.init),
                "guide": [guide.minX, guide.minY, guide.width, guide.height].map(Double.init),
                "safeBottom": Double(safeBottom),
                "keyboardInset": Double(guide.height - safeBottom)
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set { super.accessibilityValue = newValue }
    }
}
#endif

import SwiftUI
import AppKit

/// Hidden NSView that grabs its hosting `NSWindow` on first attach and
/// applies the wizard's window-chrome configuration. Must run BEFORE
/// the SwiftUI body would otherwise paint an opaque background — the
/// `dispatch_async(.main)` runs at the end of the current runloop tick,
/// well before the user sees the first frame, but after `view.window`
/// has been wired up.
///
/// Why this exists instead of doing the configuration in `.task`:
/// `.task` is async, so the WindowGroup has already shown the window
/// with default opaque chrome by the time it fires — you see a one-
/// frame flash of an opaque grey window before the glass materializes.
struct WindowConfigurator: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Convenience: install a `WindowConfigurator` as a hidden
    /// background so the closure runs once the SwiftUI view is
    /// mounted in its hosting window.
    func configureHostingWindow(_ configure: @escaping (NSWindow) -> Void) -> some View {
        background(WindowConfigurator(configure: configure))
    }
}

import SwiftUI
import UIKit

/// A native sheet's SwiftUI presentation node must outlive reconstruction of
/// its source row. Retain the anchor's hosting graph, not a second modal stack.
@MainActor
final class RetainedNativeSheetHost: PresentationScopedResource {
    private var controller: UIHostingController<AnyView>?
    private var retired = false
    var isInstalled: Bool { controller != nil }
    var isAttached: Bool { controller?.viewIfLoaded?.window != nil }

    #if HOSTED_TEST
    isolated deinit {
        if controller != nil { ForegroundSheetProbe.record("anchor-deinit", "\(ObjectIdentifier(self))") }
    }
    #endif

    func update<Content: View>(_ content: Content, environment: EnvironmentValues) -> UIHostingController<AnyView> {
        if let controller {
            if !retired { controller.rootView = AnyView(content.environment(\.self, environment)) }
            return controller
        }
        let root = retired ? AnyView(EmptyView()) : AnyView(content.environment(\.self, environment))
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        self.controller = controller
        #if HOSTED_TEST
        ForegroundSheetProbe.record("anchor-create", "\(ObjectIdentifier(self))")
        #endif
        return controller
    }

    func presentationDidRetire() {
        guard !retired else { return }
        retired = true
        #if HOSTED_TEST
        if controller != nil { ForegroundSheetProbe.record("anchor-retire", "\(ObjectIdentifier(self))") }
        #endif
        controller?.rootView = AnyView(EmptyView())
    }
}

struct RetainedNativeSheetPresenter<Anchor: View>: UIViewControllerRepresentable {
    let owner: RetainedNativeSheetHost
    @ViewBuilder let anchor: () -> Anchor

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        owner.update(anchor(), environment: context.environment)
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        _ = owner.update(anchor(), environment: context.environment)
    }
}

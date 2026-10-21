import SwiftUI
import UIKit

#if HOSTED_TEST
/// Passive observation is injected by the hosted fixture, never imported from it.
@MainActor enum HostedPresentationProbe {
    static var record: (@MainActor (String, String) -> Void)?
    static var nativeView: (@MainActor (String) -> AnyView)?
}
#endif

/// Retains the ordinary SwiftUI sheet graph for one managed presenter. Its
/// native view is mounted by the containing surface, never inside a control.
@MainActor
final class RetainedNativeSheetHost: PresentationScopedResource {
    private var controller: UIHostingController<AnyView>?
    private var retired = false
    var isInstalled: Bool { controller != nil }
    var isAttached: Bool { controller?.viewIfLoaded?.window != nil }

    isolated deinit {
        #if HOSTED_TEST
        if controller != nil { HostedPresentationProbe.record?("anchor-deinit", "\(ObjectIdentifier(self))") }
        #endif
        detach()
    }

    func mount(_ content: AnyView, environment: EnvironmentValues, parent: UIViewController) {
        guard !retired else { return }
        let root = AnyView(content.environment(\.self, environment))
        let controller: UIHostingController<AnyView>
        if let installed = self.controller {
            controller = installed
            controller.rootView = root
        } else {
            controller = UIHostingController(rootView: root)
            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            controller.view.accessibilityElementsHidden = true
            self.controller = controller
            #if HOSTED_TEST
            HostedPresentationProbe.record?("anchor-create", "\(ObjectIdentifier(self))")
            #endif
        }
        guard controller.parent !== parent else { return }
        detach()
        parent.addChild(controller)
        controller.view.frame = .zero
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
    }

    private func detach() {
        guard let controller, controller.parent != nil else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    func presentationDidRetire() {
        guard !retired else { return }
        retired = true
        #if HOSTED_TEST
        if controller != nil { HostedPresentationProbe.record?("anchor-retire", "\(ObjectIdentifier(self))") }
        #endif
        controller?.rootView = AnyView(EmptyView())
        detach()
    }
}

struct NativeSheetSource {
    let owner: RetainedNativeSheetHost
    let content: AnyView
    let environment: EnvironmentValues
}

struct NativeSheetSources: PreferenceKey {
    static var defaultValue: [NativeSheetSource] { [] }
    static func reduce(value: inout [NativeSheetSource], nextValue: () -> [NativeSheetSource]) {
        value.append(contentsOf: nextValue())
    }
}

@MainActor
private final class NativeSheetCanvas: PresentationScopedResource {
    let controller: UIViewController = {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
        return controller
    }()

    func presentationDidRetire() {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }
}

private struct NativeSheetCanvasView: UIViewControllerRepresentable {
    let canvas: NativeSheetCanvas
    let sources: [NativeSheetSource]

    func makeUIViewController(context: Context) -> UIViewController { canvas.controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        withTransaction(context.transaction) {
            for source in sources {
                source.owner.mount(source.content, environment: source.environment, parent: controller)
            }
        }
    }
}

/// One native mounting point per scene/surface, outside its controls. Sources
/// are render inputs, not a route registry: scoped resources still own lifetime.
struct TronNativeSheetCanvas: ViewModifier {
    @PresentationState private var canvas = NativeSheetCanvas()

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(NativeSheetSources.self) { sources in
            NativeSheetCanvasView(canvas: canvas, sources: sources)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // A nested surface owns its sources; an ancestor must not remount them.
        .transformPreference(NativeSheetSources.self) { $0 = [] }
    }
}

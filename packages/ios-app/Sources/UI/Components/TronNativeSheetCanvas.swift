import SwiftUI
import UIKit

#if HOSTED_TEST
/// Passive observation is injected by the hosted fixture, never imported from it.
@MainActor enum HostedPresentationProbe {
    static var record: (@MainActor (String, String) -> Void)?
    static var nativeView: (@MainActor (String) -> AnyView)?
}
#endif

/// One source's ordinary SwiftUI sheet node. The surface's retained hosting
/// root renders it; a source control never contains a platform view.
@MainActor
final class RetainedNativeSheetHost {
    private(set) var content: AnyView?
    private weak var canvas: NativeSheetCanvas?
    private var onSourceRemoval: (@MainActor () -> Void)?
    private var retired = false
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isInstalled: Bool { content != nil }
    var isAttached: Bool { canvas?.isAttached == true }

    isolated deinit {
        #if HOSTED_TEST
        if content != nil { HostedPresentationProbe.record?("anchor-deinit", "\(id)") }
        #endif
    }

    func mount(_ source: NativeSheetSource, on canvas: NativeSheetCanvas) {
        guard !retired else { return }
        #if HOSTED_TEST
        if content == nil { HostedPresentationProbe.record?("anchor-create", "\(id)") }
        #endif
        content = AnyView(source.content.environment(\.self, source.environment))
        onSourceRemoval = source.onRemoval
        self.canvas = canvas
        canvas.include(self)
    }

    func sourceWasRemoved() {
        let removal = onSourceRemoval
        onSourceRemoval = nil
        removal?()
    }
}

extension RetainedNativeSheetHost: PresentationScopedResource {
    func presentationDidRetire() {
        guard !retired else { return }
        retired = true
        onSourceRemoval = nil
        #if HOSTED_TEST
        if content != nil { HostedPresentationProbe.record?("anchor-retire", "\(id)") }
        #endif
        // Break source/scope/environment captures even while native dismissal
        // still owns the hosting root. The installed marker remains observable.
        if content != nil { content = AnyView(EmptyView()) }
        let parent = canvas
        canvas = nil
        parent?.remove(self)
    }
}

struct NativeSheetSource {
    let owner: RetainedNativeSheetHost
    let content: AnyView
    let environment: EnvironmentValues
    let onRemoval: @MainActor () -> Void
}

struct NativeSheetSources: PreferenceKey {
    static var defaultValue: [NativeSheetSource] { [] }
    static func reduce(value: inout [NativeSheetSource], nextValue: () -> [NativeSheetSource]) {
        value.append(contentsOf: nextValue())
    }
}

private struct NativeSheetCanvasContent: View {
    struct Source: Identifiable {
        let id: ObjectIdentifier
        let content: AnyView
    }
    let sources: [Source]

    var body: some View {
        ZStack { ForEach(sources) { $0.content } }
            #if HOSTED_TEST
            // Animated detent insets can leave a stable fractional scroll offset.
            // Static locks pin the native sheet transaction, not its pixels.
            .transaction { transaction in
                if ProcessInfo.processInfo.environment["TRON_UI_LOCK_RENDERING"] == "1" {
                    transaction.disablesAnimations = true
                }
            }
            #endif
    }
}

/// The hosting controller itself must survive reconstruction: retaining child
/// controllers under a disposable UIKit container still dismisses their sheets.
@MainActor
final class NativeSheetCanvas: PresentationScopedResource {
    private var sources: [RetainedNativeSheetHost] = []
    private var hostingController: UIHostingController<NativeSheetCanvasContent>?
    private var retired = false
    var isAttached: Bool { hostingController?.viewIfLoaded?.window != nil }

    var controller: UIViewController {
        if let hostingController { return hostingController }
        let controller = UIHostingController(rootView: renderedContent)
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
        hostingController = controller
        return controller
    }

    func include(_ source: RetainedNativeSheetHost) {
        guard !retired, !sources.contains(where: { $0 === source }) else { return }
        sources.append(source)
        publish()
    }

    func remove(_ source: RetainedNativeSheetHost) {
        sources.removeAll { $0 === source }
        publish()
    }

    func render(_ inputs: [NativeSheetSource], reconcileRemoval: Bool) {
        guard !retired else { return }
        for input in inputs { input.owner.mount(input, on: self) }
        publish()
        guard reconcileRemoval else { return }
        let live = Set(inputs.map { $0.owner.id })
        for source in sources where !live.contains(source.id) { source.sourceWasRemoved() }
    }

    private var renderedContent: NativeSheetCanvasContent {
        NativeSheetCanvasContent(sources: sources.compactMap { source in
            source.content.map { .init(id: source.id, content: $0) }
        })
    }

    private func publish() {
        // Explicit native-root publication also reaches covered sheet graphs;
        // an observable child value alone can wait until that root is revealed.
        hostingController?.rootView = renderedContent
    }

    func presentationDidRetire() {
        guard !retired else { return }
        retired = true
        let mounted = sources
        sources.removeAll()
        for source in mounted { source.presentationDidRetire() }
        publish()
    }
}

private struct NativeSheetCanvasView: UIViewControllerRepresentable {
    let canvas: NativeSheetCanvas
    let sources: [NativeSheetSource]

    func makeUIViewController(context: Context) -> UIViewController { canvas.controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        withTransaction(context.transaction) {
            canvas.render(sources, reconcileRemoval: context.environment.scenePhase == .active
                && controller.viewIfLoaded?.window != nil && controller.parent != nil)
        }
    }
}

/// One native mounting point per scene/surface, outside its controls. Sources
/// are render inputs, not a route registry: scoped resources still own lifetime.
struct TronNativeSheetCanvas: ViewModifier {
    @PresentationState private var canvas = NativeSheetCanvas()

    func body(content: Content) -> some View {
        let canvas = canvas
        return content.overlayPreferenceValue(NativeSheetSources.self) { sources in
            NativeSheetCanvasView(canvas: canvas, sources: sources)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // A nested surface owns its sources; an ancestor must not remount them.
        .transformPreference(NativeSheetSources.self) { $0 = [] }
    }
}

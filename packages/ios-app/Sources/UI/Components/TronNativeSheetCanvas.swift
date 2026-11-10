import SwiftUI
import UIKit

#if HOSTED_TEST
@MainActor enum HostedPresentationProbe {
    static var record: (@MainActor (String, String) -> Void)?
    static var nativeView: (@MainActor (String) -> AnyView)?
}
#endif

@MainActor
final class RetainedNativeSheetHost {
    private(set) var content: AnyView?
    private weak var canvas: NativeSheetCanvas?
    private var onSourceRemoval: (@MainActor () -> Void)?
    private var retired = false
    nonisolated let id = UUID()
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
        let id: UUID
        let content: AnyView
    }
    let sources: [Source]

    var body: some View {
        ZStack { ForEach(sources) { $0.content } }
            #if HOSTED_TEST
            .transaction { transaction in
                if ProcessInfo.processInfo.environment["TRON_UI_LOCK_RENDERING"] == "1" {
                    transaction.disablesAnimations = true
                }
            }
            #endif
    }
}

private final class NativeSheetHostingController: UIHostingController<NativeSheetCanvasContent> {
    override func present(_ presented: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        if let window = view.window { TronPadSheetMode.prepare(presented, in: window) }
        super.present(presented, animated: animated, completion: completion)
    }
}

@MainActor
final class NativeSheetCanvas: PresentationScopedResource {
    private var sources: [RetainedNativeSheetHost] = []
    private var hostingController: NativeSheetHostingController?
    private var retired = false
    var isAttached: Bool { hostingController?.viewIfLoaded?.window != nil }

    var controller: UIViewController {
        if let hostingController { return hostingController }
        let controller = NativeSheetHostingController(rootView: renderedContent)
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

enum TronSheetSurfaceRole {
    case scene, route, sheet
}

struct TronNativeSheetCanvas: ViewModifier {
    var role: TronSheetSurfaceRole = .sheet
    @PresentationState private var canvas = NativeSheetCanvas()
    @Environment(\.tronPadSheetScene) private var padSheetScene
    @State private var presentsSheet = false

    func body(content: Content) -> some View {
        let canvas = canvas
        let isPanel = role == .scene && padSheetScene?.mode == .sideColumn
        return content
            .modifier(TronSideColumnPanel(isOpen: isPanel && presentsSheet, isPanel: isPanel))
            .onPreferenceChange(TronPadSheetPresented.self) { presentsSheet = $0 }
            .overlayPreferenceValue(NativeSheetSources.self) { sources in
                NativeSheetCanvasView(canvas: canvas, sources: sources)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .transformPreference(NativeSheetSources.self) { $0 = [] }
            .transformPreference(TronPadSheetPresented.self) { if role != .route { $0 = false } }
    }
}

import SwiftUI
import TronSwiftAppEngine

private struct SwiftAppEnvironmentObjectsKey: EnvironmentKey {
    static let defaultValue: [String: SwiftAppValue] = [:]
}

private struct SwiftAppViewDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct SwiftAppHostChromeKey: EnvironmentKey {
    static let defaultValue: SwiftAppHostChrome? = nil
}

private struct SwiftAppHostedRootKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SwiftAppHostsNavigationKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SwiftAppDismissKey: EnvironmentKey {
    static let defaultValue: DismissAction? = nil
}

extension EnvironmentValues {
    var swiftAppEnvironmentObjects: [String: SwiftAppValue] {
        get { self[SwiftAppEnvironmentObjectsKey.self] }
        set { self[SwiftAppEnvironmentObjectsKey.self] = newValue }
    }
    /// How many interpreted view structs enclose this one.
    var swiftAppViewDepth: Int {
        get { self[SwiftAppViewDepthKey.self] }
        set { self[SwiftAppViewDepthKey.self] = newValue }
    }
    /// The dismiss action of the innermost presentation the program created
    /// (`SwiftAppPresentedContent`); nil in the program's root.
    /// Set from the runner's root until the program's first real view, which
    /// `SwiftAppModifiedView` wraps in a `SwiftAppHostStack` (#909).
    var swiftAppHostChrome: SwiftAppHostChrome? {
        get { self[SwiftAppHostChromeKey.self] }
        set { self[SwiftAppHostChromeKey.self] = newValue }
    }
    /// True inside the program's root as the runner hosts it, until a
    /// presentation the program creates (#909).
    var swiftAppHostedRoot: Bool {
        get { self[SwiftAppHostedRootKey.self] }
        set { self[SwiftAppHostedRootKey.self] = newValue }
    }
    /// True until the program's outermost NavigationStack, which merges into
    /// the runner sheet's own stack (`SwiftAppNavigationStack`).
    var swiftAppHostsNavigation: Bool {
        get { self[SwiftAppHostsNavigationKey.self] }
        set { self[SwiftAppHostsNavigationKey.self] = newValue }
    }
    var swiftAppDismiss: DismissAction? {
        get { self[SwiftAppDismissKey.self] }
        set { self[SwiftAppDismissKey.self] = newValue }
    }
}

/// One interpreted user view struct. SwiftUI keeps `state` alive for as long
/// as this view keeps its identity, exactly like a native `@State`.
struct SwiftAppCustomView: View {
    let runtime: SwiftAppRuntime
    let node: SwiftAppViewNode
    @State private var state: SwiftAppStateStore
    @Environment(\.swiftAppEnvironmentObjects) private var environmentObjects
    @Environment(\.swiftAppViewDepth) private var depth
    @Environment(\.swiftAppDismiss) private var dismiss
    @Environment(\.swiftAppHostChrome) private var hostChrome
    /// A view that contains itself (`struct A { var body { A() } }`) is
    /// unbounded SwiftUI recursion; it stops here with a diagnostic.
    static let maximumDepth = 48

    init(runtime: SwiftAppRuntime, node: SwiftAppViewNode) {
        self.runtime = runtime
        self.node = node
        _state = State(initialValue: runtime.initialState(for: node.declaration!, arguments: node.arguments))
    }

    var body: some View {
        if depth >= Self.maximumDepth {
            SwiftAppErrorView(message: "Stopped: views are nested too deeply")
        } else {
            switch evaluate() {
            case .success(let node):
                SwiftAppNodeView(runtime: runtime, node: node)
                    .environment(\.swiftAppViewDepth, depth + 1)
            case .failure(let error):
                if let hostChrome {
                    // A root that fails before its first view still gets the
                    // runner's chrome, so Done can close it.
                    SwiftAppHostStack(chrome: hostChrome) { SwiftAppErrorView(message: String(describing: error)) }
                } else {
                    SwiftAppErrorView(message: String(describing: error))
                }
            }
        }
    }

    private func evaluate() -> Result<SwiftAppViewNode, Error> {
        Result {
            let instance = SwiftAppViewInstance(
                declaration: node.declaration!,
                properties: try runtime.properties(for: node),
                state: state,
                environmentObjects: environmentObjects,
                dismiss: dismiss
            )
            let value = try runtime.body(of: instance)
            return SwiftAppRuntime.viewNode(from: value) ?? SwiftAppViewNode(name: "EmptyView", arguments: [])
        }
    }
}

struct SwiftAppErrorView: View {
    let message: String

    var body: some View {
        TronInfoCard(icon: "exclamationmark.triangle", text: message, accent: .tronError, usesSemanticAccent: true)
            .accessibilityIdentifier("swiftApp.error")
    }
}

/// Renders a list of sibling nodes, keeping ForEach rows transparent to the
/// enclosing List/VStack so swipe actions and lazy rows behave natively.
struct SwiftAppNodesView: View {
    let runtime: SwiftAppRuntime
    let nodes: [SwiftAppViewNode]

    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            SwiftAppNodeView(runtime: runtime, node: node)
        }
    }
}

struct SwiftAppNodeView: View {
    let runtime: SwiftAppRuntime
    let node: SwiftAppViewNode
    @Environment(\.swiftAppHostChrome) private var hostChrome

    var body: some View {
        if let hostChrome, node.name == SwiftAppRenderer.builderGroup || node.name == "ForEach" {
            // Several root views, or a root ForEach, share one runner stack.
            SwiftAppHostStack(chrome: hostChrome) { SwiftAppNodeView(runtime: runtime, node: node) }
        } else if node.name == SwiftAppRenderer.builderGroup {
            SwiftAppNodesView(runtime: runtime, nodes: node.children ?? [])
        } else if node.name == "ForEach" {
            forEach
        } else if node.declaration != nil, node.modifiers.isEmpty {
            SwiftAppCustomView(runtime: runtime, node: node)
        } else {
            SwiftAppModifiedView(runtime: runtime, node: node)
        }
    }

    @ViewBuilder
    private var forEach: some View {
        switch Result(catching: { try SwiftAppRenderer.items(of: node, runtime: runtime) }) {
        case .success(let items):
            let onDelete = node.modifiers.last(where: { $0.name == "onDelete" })?.arguments.last?.value
            let onMove = node.modifiers.last(where: { $0.name == "onMove" })?.arguments.last?.value
            ForEach(items) { item in
                SwiftAppNodeView(runtime: runtime, node: item.node)
            }
            .onDelete(perform: action(onDelete).map { perform in
                { offsets in perform([.array(offsets.map { .int($0) })]) }
            })
            .onMove(perform: action(onMove).map { perform in
                { offsets, destination in perform([.array(offsets.map { .int($0) }), .int(destination)]) }
            })
        case .failure(let error):
            SwiftAppErrorView(message: String(describing: error))
        }
    }

    private func action(_ value: SwiftAppValue?) -> (([SwiftAppValue]) -> Void)? {
        guard let value else { return nil }
        return { [runtime] arguments in runtime.perform(value, arguments) }
    }
}

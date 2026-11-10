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
    var swiftAppViewDepth: Int {
        get { self[SwiftAppViewDepthKey.self] }
        set { self[SwiftAppViewDepthKey.self] = newValue }
    }
    var swiftAppHostChrome: SwiftAppHostChrome? {
        get { self[SwiftAppHostChromeKey.self] }
        set { self[SwiftAppHostChromeKey.self] = newValue }
    }
    var swiftAppHostedRoot: Bool {
        get { self[SwiftAppHostedRootKey.self] }
        set { self[SwiftAppHostedRootKey.self] = newValue }
    }
    var swiftAppHostsNavigation: Bool {
        get { self[SwiftAppHostsNavigationKey.self] }
        set { self[SwiftAppHostsNavigationKey.self] = newValue }
    }
    var swiftAppDismiss: DismissAction? {
        get { self[SwiftAppDismissKey.self] }
        set { self[SwiftAppDismissKey.self] = newValue }
    }
}

struct SwiftAppCustomView: View {
    let runtime: SwiftAppRuntime
    let node: SwiftAppViewNode
    @State private var state: Result<SwiftAppStateStore, Error>
    @Environment(\.swiftAppEnvironmentObjects) private var environmentObjects
    @Environment(\.swiftAppViewDepth) private var depth
    @Environment(\.swiftAppDismiss) private var dismiss
    @Environment(\.swiftAppHostChrome) private var hostChrome
    static let maximumDepth = 48

    init(runtime: SwiftAppRuntime, node: SwiftAppViewNode) {
        self.runtime = runtime
        self.node = node
        _state = State(initialValue: Result { try runtime.initialState(for: node.declaration!, arguments: node.arguments) })
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
                state: try state.get(),
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
        return { [runtime] arguments in runtime.perform(value, arguments, userInitiated: true) }
    }
}

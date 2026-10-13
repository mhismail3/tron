import SwiftUI

/// Native SwiftUI rendering of interpreted view nodes (#889). Every node is a
/// real SwiftUI view; custom view structs become `SwiftAppCustomView`, whose
/// SwiftUI identity owns the interpreted `@State`.
@MainActor
enum SwiftAppRenderer {
    static let builderGroup = "_ViewBuilderGroup"

    static let viewNames: Set<String> = [
        "Text", "Label", "Image", "Button", "Toggle", "TextField", "SecureField", "Stepper", "Slider", "ProgressView",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "GridItem", "ScrollView", "List", "Form",
        "Section", "Group", "GroupBox", "DisclosureGroup", "NavigationStack", "NavigationView", "NavigationLink",
        "WindowGroup", "TabView", "ForEach", "Spacer", "Divider", "Rectangle", "RoundedRectangle", "Circle", "Capsule",
        "Ellipse", "Picker", "EmptyView", "ContentUnavailableView", "ToolbarItem", "ToolbarItemGroup",
    ]

    static let colorNames: [String: Color] = [
        "red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint, "teal": .teal,
        "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple, "pink": .pink, "brown": .brown,
        "white": .white, "gray": .gray, "black": .black, "clear": .clear, "primary": .primary,
        "secondary": .secondary, "accentColor": .accentColor,
    ]

    static func color(_ value: SwiftAppValue?) -> Color? {
        switch value?.resolved {
        case .color(let color)?: color
        case .member(let name, _)?: colorNames[name]
        default: nil
        }
    }

    static func number(_ value: SwiftAppValue?) -> CGFloat? {
        switch value?.resolved {
        case .member("infinity", _)?: .infinity
        case let value?: (try? value.asDouble()).map { CGFloat($0) }
        default: nil
        }
    }

    static func font(_ value: SwiftAppValue?) -> Font? {
        guard case .member(let name, let arguments)? = value?.resolved else { return nil }
        switch name {
        case "largeTitle": return .largeTitle
        case "title": return .title
        case "title2": return .title2
        case "title3": return .title3
        case "headline": return .headline
        case "subheadline": return .subheadline
        case "body": return .body
        case "callout": return .callout
        case "footnote": return .footnote
        case "caption": return .caption
        case "caption2": return .caption2
        case "system":
            let size = number(arguments?.first(where: { $0.label == "size" })?.value) ?? 17
            let weight = fontWeight(arguments?.first(where: { $0.label == "weight" })?.value) ?? .regular
            let design: Font.Design = switch arguments?.first(where: { $0.label == "design" })?.value {
            case .member("rounded", _)?: .rounded
            case .member("monospaced", _)?: .monospaced
            case .member("serif", _)?: .serif
            default: .default
            }
            return .system(size: size, weight: weight, design: design)
        default: return nil
        }
    }

    static func fontWeight(_ value: SwiftAppValue?) -> Font.Weight? {
        guard case .member(let name, _)? = value?.resolved else { return nil }
        return [
            "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
            "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
        ][name]
    }

    static func horizontalAlignment(_ value: SwiftAppValue?) -> HorizontalAlignment {
        guard case .member(let name, _)? = value?.resolved else { return .center }
        return name == "leading" ? .leading : name == "trailing" ? .trailing : .center
    }

    static func verticalAlignment(_ value: SwiftAppValue?) -> VerticalAlignment {
        guard case .member(let name, _)? = value?.resolved else { return .center }
        return name == "top" ? .top : name == "bottom" ? .bottom : name == "firstTextBaseline" ? .firstTextBaseline : .center
    }

    static func alignment(_ value: SwiftAppValue?) -> Alignment {
        guard case .member(let name, _)? = value?.resolved else { return .center }
        return [
            "leading": .leading, "trailing": .trailing, "top": .top, "bottom": .bottom, "topLeading": .topLeading,
            "topTrailing": .topTrailing, "bottomLeading": .bottomLeading, "bottomTrailing": .bottomTrailing,
        ][name] ?? .center
    }

    static func edges(_ value: SwiftAppValue?) -> Edge.Set? {
        guard case .member(let name, _)? = value?.resolved else { return nil }
        return [
            "all": .all, "horizontal": .horizontal, "vertical": .vertical, "top": .top, "bottom": .bottom,
            "leading": .leading, "trailing": .trailing,
        ][name]
    }

    static func animation(_ value: SwiftAppValue?) -> Animation? {
        guard case .member(let name, _)? = value?.resolved else { return .default }
        switch name {
        case "spring", "bouncy", "snappy", "smooth": return .spring
        case "easeIn": return .easeIn
        case "easeOut": return .easeOut
        case "easeInOut": return .easeInOut
        case "linear": return .linear
        default: return .default
        }
    }

    static func closedRange(_ value: SwiftAppValue?) -> ClosedRange<Double>? {
        switch value?.resolved {
        case .range(let lower, let upper)? where upper > lower: Double(lower)...Double(upper - 1)
        case .doubleRange(let lower, let upper)? where upper >= lower: lower...upper
        default: nil
        }
    }

    static func shape(_ node: SwiftAppViewNode) -> AnyShape? {
        switch node.name {
        case "Rectangle": AnyShape(Rectangle())
        case "RoundedRectangle": AnyShape(RoundedRectangle(cornerRadius: number(node.argument("cornerRadius")) ?? 8, style: .continuous))
        case "Circle": AnyShape(Circle())
        case "Capsule": AnyShape(Capsule())
        case "Ellipse": AnyShape(Ellipse())
        default: nil
        }
    }

    static func shape(_ value: SwiftAppValue?) -> AnyShape? {
        switch value?.resolved {
        case .view(let node)?: shape(node)
        case .member("circle", _)?: AnyShape(Circle())
        case .member("capsule", _)?: AnyShape(Capsule())
        case .member("rect", let arguments)?:
            AnyShape(RoundedRectangle(cornerRadius: number(arguments?.first(where: { $0.label == "cornerRadius" })?.value) ?? 0, style: .continuous))
        default: nil
        }
    }

    // MARK: Children

    struct Item: Identifiable {
        let id: String
        let node: SwiftAppViewNode
        /// The ForEach element, used as the implicit `tag` for pickers.
        let element: SwiftAppValue?
    }

    /// The builder content of a container: its eager children or its content closure.
    static func content(of node: SwiftAppViewNode, runtime: SwiftAppRuntime, label: String? = nil) throws -> [SwiftAppViewNode] {
        if let children = node.children { return children }
        let closure = label.flatMap { name in node.closures.first(where: { $0.label == name })?.closure }
            ?? node.closures.first(where: { $0.label == nil || $0.label == "content" })?.closure
        guard let closure else { return [] }
        return flattenGroups(try runtime.call(closure, []))
    }

    static func flattenGroups(_ value: SwiftAppValue) -> [SwiftAppViewNode] {
        guard let node = SwiftAppRuntime.viewNode(from: value) else { return [] }
        if node.name == builderGroup, let children = node.children { return children }
        return [node]
    }

    static func items(of node: SwiftAppViewNode, runtime: SwiftAppRuntime) throws -> [Item] {
        guard let data = node.unlabeled.first, let closure = node.closures.last?.closure else {
            throw SwiftAppRuntimeError("ForEach needs data and a content closure")
        }
        var keyPath: [String]?
        if case .keyPath(let path)? = node.argument("id") { keyPath = path }
        let elements: [SwiftAppValue]
        if case .binding(let binding) = data {
            let count = try binding.get().asArray().count
            elements = (0..<count).map { index in
                .binding(SwiftAppBinding(
                    get: { (try? binding.get().asArray()).flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? .none },
                    set: { newValue in
                        guard var values = try? binding.get().asArray(), values.indices.contains(index) else { return }
                        values[index] = newValue
                        binding.set(.array(values))
                    }
                ))
            }
        } else {
            elements = try data.resolved.asArray()
        }
        var seen: [String: Int] = [:]
        return try elements.map { element in
            var id = element.resolved.identity(keyPath: keyPath)
            if let count = seen[id] { seen[id] = count + 1; id += "#\(count + 1)" } else { seen[id] = 0 }
            let produced = flattenGroups(try runtime.call(closure, [element]))
            let child = produced.count == 1 ? produced[0] : SwiftAppViewNode(name: builderGroup, arguments: [], children: produced)
            return Item(id: id, node: child, element: element.resolved)
        }
    }
}

private struct SwiftAppEnvironmentObjectsKey: EnvironmentKey {
    static let defaultValue: [String: SwiftAppValue] = [:]
}

extension EnvironmentValues {
    var swiftAppEnvironmentObjects: [String: SwiftAppValue] {
        get { self[SwiftAppEnvironmentObjectsKey.self] }
        set { self[SwiftAppEnvironmentObjectsKey.self] = newValue }
    }
}

/// One interpreted user view struct. SwiftUI keeps `state` alive for as long
/// as this view keeps its identity, exactly like a native `@State`.
struct SwiftAppCustomView: View {
    let runtime: SwiftAppRuntime
    let node: SwiftAppViewNode
    @State private var state: SwiftAppStateStore
    @Environment(\.swiftAppEnvironmentObjects) private var environmentObjects

    init(runtime: SwiftAppRuntime, node: SwiftAppViewNode) {
        self.runtime = runtime
        self.node = node
        _state = State(initialValue: runtime.initialState(for: node.declaration!, arguments: node.arguments))
    }

    var body: some View {
        switch evaluate() {
        case .success(let node): SwiftAppNodeView(runtime: runtime, node: node)
        case .failure(let error): SwiftAppErrorView(message: String(describing: error))
        }
    }

    private func evaluate() -> Result<SwiftAppViewNode, Error> {
        Result {
            let instance = SwiftAppViewInstance(
                declaration: node.declaration!,
                properties: try runtime.properties(for: node),
                state: state,
                environmentObjects: environmentObjects
            )
            let value = try runtime.body(of: instance)
            return SwiftAppRuntime.viewNode(from: value) ?? SwiftAppViewNode(name: "EmptyView", arguments: [])
        }
    }
}

struct SwiftAppErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(8)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    var body: some View {
        if node.name == SwiftAppRenderer.builderGroup {
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

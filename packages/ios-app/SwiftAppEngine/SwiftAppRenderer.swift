import SwiftUI

/// Conversions from interpreted values to native SwiftUI values and children
/// (#889). The app's node views (`Sources/UI/SwiftApps/SwiftAppNodeViews.swift`)
/// render every node as a real SwiftUI view with them; custom view structs
/// become `SwiftAppCustomView`, whose SwiftUI identity owns the interpreted
/// `@State`. Constants the app reads are computed so reading them runs this
/// module's code (tools/work/README.md#module-scoped-journeys).
@MainActor
package enum SwiftAppRenderer {
    package static var builderGroup: String { "_ViewBuilderGroup" }
    package static var diagnostic: String { "_SwiftAppDiagnostic" }

    static let viewNames: Set<String> = [
        "Text", "Label", "Image", "Button", "Toggle", "TextField", "SecureField", "Stepper", "Slider", "ProgressView",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "GridItem", "ScrollView", "List", "Form",
        "Section", "Group", "GroupBox", "DisclosureGroup", "NavigationStack", "NavigationView", "NavigationLink", "Link",
        "WindowGroup", "TabView", "ForEach", "Spacer", "Divider", "Rectangle", "RoundedRectangle", "Circle", "Capsule",
        "Ellipse", "Picker", "EmptyView", "ContentUnavailableView", "ToolbarItem", "ToolbarItemGroup", "GeometryReader",
    ]

    static let colorNames: [String: Color] = [
        "red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint, "teal": .teal,
        "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple, "pink": .pink, "brown": .brown,
        "white": .white, "gray": .gray, "black": .black, "clear": .clear, "primary": .primary,
        "secondary": .secondary, "accentColor": .accentColor,
    ]

    package static func color(_ value: SwiftAppValue?) -> Color? {
        switch value?.symbol {
        case .color(let color)?: color
        case .member(let name, _)?: colorNames[name]
        default: nil
        }
    }

    package static func number(_ value: SwiftAppValue?) -> CGFloat? {
        switch value?.symbol {
        case .member("infinity", _)?: .infinity
        // Finite sizes are clamped so a program cannot request a gigantic
        // frame, padding or font whose rendering exhausts memory.
        case let value?: (try? value.asDouble()).flatMap { $0.isNaN ? nil : CGFloat(min(max($0, -10_000), 10_000)) }
        default: nil
        }
    }

    package static func font(_ value: SwiftAppValue?) -> Font? {
        guard case .member(let name, let arguments)? = value?.symbol else { return nil }
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
            let design: Font.Design = switch arguments?.first(where: { $0.label == "design" })?.value.symbol {
            case .member("rounded", _)?: .rounded
            case .member("monospaced", _)?: .monospaced
            case .member("serif", _)?: .serif
            default: .default
            }
            return .system(size: size, weight: weight, design: design)
        default: return nil
        }
    }

    package static func fontWeight(_ value: SwiftAppValue?) -> Font.Weight? {
        guard case .member(let name, _)? = value?.symbol else { return nil }
        return [
            "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
            "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
        ][name]
    }

    package static func horizontalAlignment(_ value: SwiftAppValue?) -> HorizontalAlignment {
        guard case .member(let name, _)? = value?.symbol else { return .center }
        return name == "leading" ? .leading : name == "trailing" ? .trailing : .center
    }

    package static func verticalAlignment(_ value: SwiftAppValue?) -> VerticalAlignment {
        guard case .member(let name, _)? = value?.symbol else { return .center }
        return name == "top" ? .top : name == "bottom" ? .bottom : name == "firstTextBaseline" ? .firstTextBaseline : .center
    }

    package static func alignment(_ value: SwiftAppValue?) -> Alignment {
        guard case .member(let name, _)? = value?.symbol else { return .center }
        return [
            "leading": .leading, "trailing": .trailing, "top": .top, "bottom": .bottom, "topLeading": .topLeading,
            "topTrailing": .topTrailing, "bottomLeading": .bottomLeading, "bottomTrailing": .bottomTrailing,
        ][name] ?? .center
    }

    package static func edges(_ value: SwiftAppValue?) -> Edge.Set? {
        guard case .member(let name, _)? = value?.symbol else { return nil }
        return [
            "all": .all, "horizontal": .horizontal, "vertical": .vertical, "top": .top, "bottom": .bottom,
            "leading": .leading, "trailing": .trailing,
        ][name]
    }

    package static func animation(_ value: SwiftAppValue?) -> Animation? {
        guard case .member(let name, _)? = value?.symbol else { return .default }
        switch name {
        case "spring", "bouncy", "snappy", "smooth": return .spring
        case "easeIn": return .easeIn
        case "easeOut": return .easeOut
        case "easeInOut": return .easeInOut
        case "linear": return .linear
        default: return .default
        }
    }

    package static func closedRange(_ value: SwiftAppValue?) -> ClosedRange<Double>? {
        switch value?.symbol {
        case .range(let lower, let upper)? where upper > lower: Double(lower)...Double(upper - 1)
        case .doubleRange(let lower, let upper)? where upper >= lower: lower...upper
        default: nil
        }
    }

    package static func shape(_ node: SwiftAppViewNode) -> AnyShape? {
        switch node.name {
        case "Rectangle": AnyShape(Rectangle())
        case "RoundedRectangle": AnyShape(RoundedRectangle(cornerRadius: number(node.argument("cornerRadius")) ?? 8, style: .continuous))
        case "Circle": AnyShape(Circle())
        case "Capsule": AnyShape(Capsule())
        case "Ellipse": AnyShape(Ellipse())
        default: nil
        }
    }

    package static func shape(_ value: SwiftAppValue?) -> AnyShape? {
        switch value?.symbol {
        case .view(let node)?: shape(node)
        case .member("circle", _)?: AnyShape(Circle())
        case .member("capsule", _)?: AnyShape(Capsule())
        case .member("rect", let arguments)?:
            AnyShape(RoundedRectangle(cornerRadius: number(arguments?.first(where: { $0.label == "cornerRadius" })?.value) ?? 0, style: .continuous))
        default: nil
        }
    }

    // MARK: Children

    package struct Item: Identifiable {
        package let id: String
        package let node: SwiftAppViewNode
        /// The ForEach element, used as the implicit `tag` for pickers.
        package let element: SwiftAppValue?

        package init(id: String, node: SwiftAppViewNode, element: SwiftAppValue?) {
            self.id = id
            self.node = node
            self.element = element
        }
    }

    /// The builder content of a container: its eager children or its content closure.
    package static func content(of node: SwiftAppViewNode, runtime: SwiftAppRuntime, label: String? = nil) throws -> [SwiftAppViewNode] {
        if let children = node.children { return children }
        let closure = label.flatMap { name in node.closures.first(where: { $0.label == name })?.closure }
            ?? node.closures.first(where: { $0.label == nil || $0.label == "content" })?.closure
        guard let closure else { return [] }
        return flattenGroups(try runtime.call(closure, [], viewBuilder: true))
    }

    package static func flattenGroups(_ value: SwiftAppValue) -> [SwiftAppViewNode] {
        guard let node = SwiftAppRuntime.viewNode(from: value) else { return [] }
        if node.name == builderGroup, let children = node.children { return children }
        return [node]
    }

    package static func items(of node: SwiftAppViewNode, runtime: SwiftAppRuntime) throws -> [Item] {
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
                    get: { (try? binding.get().asArray()).flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? .nilValue },
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
            let produced = flattenGroups(try runtime.call(closure, [element], viewBuilder: true))
            let child = produced.count == 1 ? produced[0] : SwiftAppViewNode(name: builderGroup, arguments: [], children: produced)
            return Item(id: id, node: child, element: element.resolved)
        }
    }
}

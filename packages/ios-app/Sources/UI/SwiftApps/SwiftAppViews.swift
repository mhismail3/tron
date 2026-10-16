import SwiftUI

// Built-in SwiftUI views and modifiers of the experimental runtime (#889).

/// Evaluates a builder closure or view value only when SwiftUI asks for it
/// (navigation destinations, sheets, toolbar and tab content).
/// Content of a presentation the program created (a `sheet` or a
/// `NavigationLink` destination). Its views' `@Environment(\.dismiss)` closes
/// this presentation, the way SwiftUI's does, and never the runner sheet.
struct SwiftAppPresentedContent: View {
    let runtime: SwiftAppRuntime
    let value: SwiftAppValue?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SwiftAppLazyContent(runtime: runtime, value: value)
            .environment(\.swiftAppDismiss, dismiss)
            // A presentation leaves the runner's hosted root: its own
            // NavigationStack and title are the program's, not the sheet's.
            .environment(\.swiftAppHostedRoot, false)
            .environment(\.swiftAppHostsNavigation, false)
    }
}

/// What the runner gives the program's root (#909): until the program's
/// first non-container view, `swiftAppHostChrome` is set, and that view is
/// wrapped in a `SwiftAppHostStack`.
struct SwiftAppHostChrome {
    /// The sheet title when the program sets no root `navigationTitle`.
    let title: String

    /// Containers the program's root passes through before its first real view.
    @MainActor static func passesThrough(_ node: SwiftAppViewNode) -> Bool {
        node.declaration != nil || ["WindowGroup", "TabView"].contains(node.name)
            || (node.name == "Group" && node.modifiers.isEmpty)
    }
    static let tabModifiers: Set<String> = ["tabItem", "badge", "tag"]
}

/// One navigation stack the runner owns, with the shared document sheet
/// chrome (`tronDocumentSheetChrome`): the program's root `navigationTitle`
/// (else the file name), and Done, which closes the runner. A root TabView
/// gets one per tab, because a stack around a TabView would hide each tab's
/// own toolbar.
struct SwiftAppHostStack<Content: View>: View {
    let chrome: SwiftAppHostChrome
    @ViewBuilder let content: () -> Content
    @State private var programTitle: String?

    var body: some View {
        NavigationStack {
            content()
                .environment(\.swiftAppHostChrome, nil)
                .environment(\.swiftAppHostsNavigation, true)
                .environment(\.swiftAppHostedRoot, true)
                .onPreferenceChange(SwiftAppRootTitleKey.self) { programTitle = $0 }
                .tronDocumentSheetChrome(title: programTitle ?? chrome.title)
        }
    }
}

/// The program's outermost `NavigationStack` merges into the runner's shared
/// `TronDocumentSheet` stack, so its title, toolbar and pushes use the sheet's
/// navigation bar instead of nesting a second stack inside it (#909). Any other
/// stack (inside a sheet the program presents) stays a real NavigationStack.
struct SwiftAppNavigationStack: View {
    let content: AnyView
    @Environment(\.swiftAppHostsNavigation) private var hosted

    var body: some View {
        if hosted {
            content.environment(\.swiftAppHostsNavigation, false)
        } else {
            NavigationStack { content }
        }
    }
}

/// `navigationTitle`. In the runner's hosted root it also names the shared
/// sheet title (`SwiftAppRootTitleKey`), so the program's own title wins over
/// the file name.
struct SwiftAppNavigationTitle: View {
    let content: AnyView
    let title: String
    @Environment(\.swiftAppHostedRoot) private var hostedRoot

    var body: some View {
        if hostedRoot {
            content.navigationTitle(title).preference(key: SwiftAppRootTitleKey.self, value: title)
        } else {
            content.navigationTitle(title)
        }
    }
}

struct SwiftAppRootTitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

struct SwiftAppLazyContent: View {
    let runtime: SwiftAppRuntime
    let value: SwiftAppValue?
    var arguments: [SwiftAppValue] = []

    var body: some View {
        switch Result(catching: { () throws -> [SwiftAppViewNode] in
            switch value {
            case .closure?, .function?: SwiftAppRenderer.flattenGroups(try runtime.renderContent(value!, arguments: arguments))
            case let value?: SwiftAppRenderer.flattenGroups(value)
            case nil: []
            }
        }) {
        case .success(let nodes): SwiftAppNodesView(runtime: runtime, nodes: nodes)
        case .failure(let error): SwiftAppErrorView(message: String(describing: error))
        }
    }
}

struct SwiftAppTimerReceiver<Content: View>: View {
    let runtime: SwiftAppRuntime
    let action: SwiftAppValue
    let content: Content
    @State private var subscription: SwiftAppTimerSubscription

    init(runtime: SwiftAppRuntime, interval: TimeInterval, action: SwiftAppValue, content: Content) {
        self.runtime = runtime
        self.action = action
        self.content = content
        _subscription = State(initialValue: SwiftAppTimerSubscription(interval: interval))
    }

    var body: some View {
        content
            .onAppear { runtime.startTimer(subscription) }
            .onReceive(subscription.publisher) { date in
                guard runtime.isTimerActive(subscription.id) else { return }
                let succeeded = runtime.perform(action, [.date(date)])
                runtime.timerActionCompleted(subscription.id, succeeded: succeeded)
            }
            .onDisappear { runtime.stopTimer(subscription.id) }
    }
}

struct SwiftAppModifiedView: View {
    let runtime: SwiftAppRuntime
    let node: SwiftAppViewNode

    var body: some View {
        switch Result(catching: { try build() }) {
        case .success(let view): view
        case .failure(let error): AnyView(SwiftAppErrorView(message: String(describing: error)))
        }
    }

    @Environment(\.swiftAppHostChrome) private var hostChrome

    private func build() throws -> AnyView {
        // The program's first view that is not a pass-through container gets
        // the runner's navigation stack and shared chrome (#909). A tab's own
        // tabItem/badge/tag stay outside it so the TabView still reads them.
        guard let hostChrome, !SwiftAppHostChrome.passesThrough(node) else {
            return try modified(try base(), node.modifiers)
        }
        let tabLevel = node.modifiers.filter { SwiftAppHostChrome.tabModifiers.contains($0.name) }
        let inner = node.modifiers.filter { !SwiftAppHostChrome.tabModifiers.contains($0.name) }
        let inside = try modified(try base(), inner)
        return try modified(AnyView(SwiftAppHostStack(chrome: hostChrome) { inside }), tabLevel)
    }

    private func modified(_ base: AnyView, _ modifiers: [(name: String, arguments: [SwiftAppLabeledValue])]) throws -> AnyView {
        var view = base
        for modifier in modifiers {
            view = try apply(modifier.name, modifier.arguments, to: view)
        }
        return view
    }

    // MARK: Bindings

    private func bindingValue(_ label: String) -> SwiftAppBinding? {
        if case .binding(let binding)? = node.argument(label) { return binding }
        return nil
    }

    private func boolBinding(_ binding: SwiftAppBinding) -> Binding<Bool> {
        Binding(get: { (try? binding.get().asBool()) ?? false }, set: { binding.set(.bool($0)) })
    }

    private func stringBinding(_ binding: SwiftAppBinding) -> Binding<String> {
        Binding(get: { binding.get().resolved.display }, set: { binding.set(.string($0)) })
    }

    private func doubleBinding(_ binding: SwiftAppBinding) -> Binding<Double> {
        Binding(
            get: { (try? binding.get().asDouble()) ?? 0 },
            set: { newValue in binding.set(binding.get().resolved.isInt ? .int(Int(newValue.rounded())) : .double(newValue)) }
        )
    }

    private func text(_ value: SwiftAppValue?) -> String { value?.resolved.display ?? "" }

    private var title: String? {
        for value in node.unlabeled {
            if case .string(let text) = value.resolved { return text }
        }
        return nil
    }

    private func nodes(_ label: String? = nil) throws -> AnyView {
        AnyView(SwiftAppNodesView(runtime: runtime, nodes: try SwiftAppRenderer.content(of: node, runtime: runtime, label: label)))
    }

    private func lazy(_ value: SwiftAppValue?) -> SwiftAppLazyContent {
        SwiftAppLazyContent(runtime: runtime, value: value)
    }

    private func closure(_ label: String?) -> SwiftAppValue? {
        node.closures.first(where: { $0.label == label }).map { .closure($0.closure) }
    }

    // MARK: Views

    private func base() throws -> AnyView {
        let runtime = runtime
        switch node.name {
        case SwiftAppRenderer.diagnostic:
            return AnyView(SwiftAppErrorView(message: text(node.unlabeled.first)))
        case "Text":
            return AnyView(Text(verbatim: text(node.argument("verbatim") ?? node.unlabeled.first)))
        case "Label":
            return AnyView(Label(title ?? "", systemImage: text(node.argument("systemImage"))))
        case "Image":
            return AnyView(Image(systemName: node.argument("systemName").map(text) ?? "photo"))
        case "Button":
            let action: SwiftAppValue?
            let label: SwiftAppValue?
            if let explicit = node.argument("action") {
                action = explicit
                label = closure("label") ?? closure(nil)
            } else {
                action = closure(nil)
                label = closure("label")
            }
            let role: ButtonRole? = switch node.argument("role")?.symbol {
            case .member("destructive", _)?: .destructive
            case .member("cancel", _)?: .cancel
            default: nil
            }
            let systemImage = node.argument("systemImage").map(text)
            let title = title ?? ""
            return AnyView(Button(role: role) {
                if let action { runtime.perform(action) }
            } label: {
                if let label {
                    SwiftAppLazyContent(runtime: runtime, value: label)
                } else if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(verbatim: title)
                }
            })
        case "Toggle":
            guard let binding = bindingValue("isOn") else { throw SwiftAppRuntimeError("Toggle needs isOn: $state") }
            let label = closure(nil)
            let title = title ?? ""
            return AnyView(Toggle(isOn: boolBinding(binding)) {
                if let label { SwiftAppLazyContent(runtime: runtime, value: label) } else { Text(verbatim: title) }
            })
        case "TextField", "SecureField":
            guard let binding = bindingValue("text") else { throw SwiftAppRuntimeError("\(node.name) needs text: $state") }
            if node.name == "SecureField" { return AnyView(SecureField(title ?? "", text: stringBinding(binding))) }
            if case .member("vertical", _)? = node.argument("axis")?.symbol {
                return AnyView(TextField(title ?? "", text: stringBinding(binding), axis: .vertical))
            }
            return AnyView(TextField(title ?? "", text: stringBinding(binding)))
        case "Stepper":
            guard let binding = bindingValue("value") else { throw SwiftAppRuntimeError("Stepper needs value: $state") }
            let step = SwiftAppRenderer.number(node.argument("step")).map(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 1
            let label = closure(nil)
            let title = title ?? ""
            let labelView = Group {
                if let label { SwiftAppLazyContent(runtime: runtime, value: label) } else { Text(verbatim: title) }
            }
            if let range = SwiftAppRenderer.closedRange(node.argument("in")) {
                return AnyView(Stepper(value: doubleBinding(binding), in: range, step: step) { labelView })
            }
            return AnyView(Stepper(value: doubleBinding(binding), step: step) { labelView })
        case "Slider":
            guard let binding = bindingValue("value") else { throw SwiftAppRuntimeError("Slider needs value: $state") }
            let range = SwiftAppRenderer.closedRange(node.argument("in")) ?? 0...1
            if let step = SwiftAppRenderer.number(node.argument("step")), step > 0 {
                return AnyView(Slider(value: doubleBinding(binding), in: range, step: Double(step)))
            }
            return AnyView(Slider(value: doubleBinding(binding), in: range))
        case "ProgressView":
            if let value = node.argument("value") {
                let total = (try? node.argument("total")?.asDouble()) ?? 1
                return AnyView(ProgressView(title ?? "", value: min(max(0, (try? value.asDouble()) ?? 0), total), total: total))
            }
            return AnyView(Group { if let title { ProgressView(title) } else { ProgressView() } })
        case "GeometryReader":
            let content = node.argument("content") ?? node.unlabeled.first
            guard case .closure? = content else { throw SwiftAppRuntimeError("GeometryReader needs a content closure") }
            return AnyView(GeometryReader { proxy in
                SwiftAppLazyContent(runtime: runtime, value: content, arguments: [.geometry(SwiftAppGeometryValue(size: proxy.size))])
            })
        case "VStack", "LazyVStack":
            let alignment = SwiftAppRenderer.horizontalAlignment(node.argument("alignment"))
            let spacing = SwiftAppRenderer.number(node.argument("spacing"))
            let content = try nodes()
            return node.name == "VStack"
                ? AnyView(VStack(alignment: alignment, spacing: spacing) { content })
                : AnyView(LazyVStack(alignment: alignment, spacing: spacing) { content })
        case "HStack", "LazyHStack":
            let alignment = SwiftAppRenderer.verticalAlignment(node.argument("alignment"))
            let spacing = SwiftAppRenderer.number(node.argument("spacing"))
            let content = try nodes()
            return node.name == "HStack"
                ? AnyView(HStack(alignment: alignment, spacing: spacing) { content })
                : AnyView(LazyHStack(alignment: alignment, spacing: spacing) { content })
        case "ZStack":
            let content = try nodes()
            return AnyView(ZStack(alignment: SwiftAppRenderer.alignment(node.argument("alignment"))) { content })
        case "LazyVGrid":
            let count = max(1, (try? node.argument("columns")?.asArray().count) ?? 2)
            let spacing = SwiftAppRenderer.number(node.argument("spacing"))
            let content = try nodes()
            return AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: count), spacing: spacing) { content })
        case "ScrollView":
            let horizontal: Bool = if case .member("horizontal", _)? = node.unlabeled.first?.symbol { true } else { false }
            let content = try nodes()
            return AnyView(ScrollView(horizontal ? .horizontal : .vertical) { content }.tronScrollEdgeChrome())
        case "List":
            if node.unlabeled.contains(where: { if case .closure = $0 { false } else { true } }) {
                // `List(items) { item in … }` is a List around a ForEach.
                let rows = SwiftAppViewNode(name: "ForEach", arguments: node.arguments)
                return AnyView(List { SwiftAppNodeView(runtime: runtime, node: rows) }.tronScrollEdgeChrome())
            }
            let content = try nodes()
            return AnyView(List { content }.tronScrollEdgeChrome())
        case "Form":
            let content = try nodes()
            return AnyView(Form { content }.tronScrollEdgeChrome())
        case "Group", "WindowGroup", "ToolbarItem", "ToolbarItemGroup":
            return try nodes()
        case "GroupBox":
            let content = try nodes()
            let title = title
            return AnyView(GroupBox { content } label: { if let title { Text(verbatim: title) } })
        case "DisclosureGroup":
            let content = try nodes()
            return AnyView(DisclosureGroup(title ?? "") { content })
        case "Section":
            let content = try SwiftAppRenderer.content(of: node, runtime: runtime)
            let header = closure("header")
            let footer = closure("footer")
            let title = title
            return AnyView(Section {
                SwiftAppNodesView(runtime: runtime, nodes: content)
            } header: {
                if let header { SwiftAppLazyContent(runtime: runtime, value: header) } else if let title { Text(verbatim: title) }
            } footer: {
                if let footer { SwiftAppLazyContent(runtime: runtime, value: footer) }
            })
        case "NavigationStack", "NavigationView":
            return AnyView(SwiftAppNavigationStack(content: try nodes()))
        case "TabView":
            let content = try nodes()
            return AnyView(TabView { content })
        case "NavigationLink":
            let destination: SwiftAppValue?
            let label: SwiftAppValue?
            if let explicit = node.argument("destination") {
                destination = explicit
                label = closure("label") ?? closure(nil)
            } else {
                destination = closure(nil)
                label = closure("label")
            }
            let title = title ?? ""
            return AnyView(NavigationLink {
                SwiftAppPresentedContent(runtime: runtime, value: destination)
            } label: {
                if let label { SwiftAppLazyContent(runtime: runtime, value: label) } else { Text(verbatim: title) }
            })
        case "Spacer":
            return AnyView(Spacer(minLength: SwiftAppRenderer.number(node.argument("minLength"))))
        case "Divider":
            return AnyView(Divider())
        case "EmptyView":
            return AnyView(EmptyView())
        case "Color":
            return AnyView(SwiftAppRenderer.color(node.unlabeled.first) ?? .clear)
        case "Rectangle", "RoundedRectangle", "Circle", "Capsule", "Ellipse":
            guard let shape = SwiftAppRenderer.shape(node) else { return AnyView(EmptyView()) }
            if let stroke = node.modifiers.last(where: { $0.name == "stroke" }) {
                let color = SwiftAppRenderer.color(stroke.arguments.first?.value) ?? .primary
                let width = SwiftAppRenderer.number(stroke.arguments.first(where: { $0.label == "lineWidth" })?.value) ?? 1
                return AnyView(shape.stroke(color, lineWidth: width))
            }
            let fill = node.modifiers.last(where: { $0.name == "fill" || $0.name == "foregroundStyle" })
            return AnyView(shape.fill(SwiftAppRenderer.color(fill?.arguments.first?.value) ?? .primary))
        case "ContentUnavailableView":
            let description = node.argument("description").flatMap { value -> String? in
                if case .view(let textNode) = value { return text(textNode.unlabeled.first) }
                return text(value)
            }
            return AnyView(ContentUnavailableView(
                title ?? "",
                systemImage: text(node.argument("systemImage")),
                description: description.map { Text(verbatim: $0) }
            ))
        case "Picker":
            return try picker()
        default:
            if node.declaration != nil { return AnyView(SwiftAppCustomView(runtime: runtime, node: node)) }
            throw SwiftAppRuntimeError("\(node.name) is not supported yet")
        }
    }

    private func picker() throws -> AnyView {
        guard let selection = bindingValue("selection") else { throw SwiftAppRuntimeError("Picker needs selection: $state") }
        var options: [(id: String, node: SwiftAppViewNode)] = []
        var tags: [String: SwiftAppValue] = [:]
        for child in try SwiftAppRenderer.content(of: node, runtime: runtime) {
            let items = child.name == "ForEach"
                ? try SwiftAppRenderer.items(of: child, runtime: runtime)
                : [SwiftAppRenderer.Item(id: String(options.count), node: child, element: nil)]
            for item in items {
                var option = item.node
                let tag = option.modifiers.last(where: { $0.name == "tag" })?.arguments.first?.value.resolved ?? item.element ?? .string(item.id)
                option.modifiers.removeAll { $0.name == "tag" }
                let id = tag.identity(keyPath: ["self"])
                tags[id] = tag
                options.append((id, option))
            }
        }
        let binding = Binding<String>(
            get: { selection.get().resolved.identity(keyPath: ["self"]) },
            set: { id in if let tag = tags[id] { selection.set(tag) } }
        )
        let runtime = runtime
        return AnyView(Picker(title ?? "", selection: binding) {
            ForEach(options, id: \.id) { option in
                SwiftAppNodeView(runtime: runtime, node: option.node).tag(option.id)
            }
        })
    }

    // MARK: Modifiers

    private func argument(_ arguments: [SwiftAppLabeledValue], _ label: String? = nil) -> SwiftAppValue? {
        if let label { return arguments.first(where: { $0.label == label })?.value }
        return arguments.first(where: { $0.label == nil })?.value
    }

    private func apply(_ name: String, _ arguments: [SwiftAppLabeledValue], to view: AnyView) throws -> AnyView {
        let runtime = runtime
        let first = arguments.first?.value.symbol
        switch name {
        case "padding":
            if arguments.isEmpty { return AnyView(view.padding()) }
            if let edges = SwiftAppRenderer.edges(first) {
                return AnyView(view.padding(edges, arguments.count > 1 ? SwiftAppRenderer.number(arguments[1].value) : nil))
            }
            return AnyView(view.padding(SwiftAppRenderer.number(first) ?? 16))
        case "font": return AnyView(view.font(SwiftAppRenderer.font(first)))
        case "fontWeight": return AnyView(view.fontWeight(SwiftAppRenderer.fontWeight(first)))
        case "bold": return AnyView(view.bold((try? first?.asBool()) ?? true))
        case "italic": return AnyView(view.italic((try? first?.asBool()) ?? true))
        case "monospaced": return AnyView(view.monospaced())
        case "monospacedDigit": return AnyView(view.monospacedDigit())
        case "underline": return AnyView(view.underline((try? first?.asBool()) ?? true))
        case "strikethrough": return AnyView(view.strikethrough((try? first?.asBool()) ?? true))
        case "foregroundStyle", "foregroundColor":
            if node.name == "Rectangle" || node.name == "RoundedRectangle" || node.name == "Circle" || node.name == "Capsule" { return view }
            if case .member("tertiary", _)? = first { return AnyView(view.foregroundStyle(.tertiary)) }
            return AnyView(view.foregroundStyle(SwiftAppRenderer.color(first) ?? .primary))
        case "tint": return AnyView(view.tint(SwiftAppRenderer.color(first)))
        case "background":
            if let shape = SwiftAppRenderer.shape(argument(arguments, "in")) {
                if case .member(let material, _)? = first, material.hasSuffix("Material") {
                    return AnyView(view.background(.regularMaterial, in: shape))
                }
                return AnyView(view.background(SwiftAppRenderer.color(first) ?? .clear, in: shape))
            }
            if let color = SwiftAppRenderer.color(first) { return AnyView(view.background(color)) }
            if case .member(let material, _)? = first, material.hasSuffix("Material") { return AnyView(view.background(.regularMaterial)) }
            return AnyView(view.background { SwiftAppLazyContent(runtime: runtime, value: first) })
        case "overlay":
            let alignment = SwiftAppRenderer.alignment(argument(arguments, "alignment"))
            let content = argument(arguments) ?? arguments.last?.value
            return AnyView(view.overlay(alignment: alignment) { SwiftAppLazyContent(runtime: runtime, value: content) })
        case "frame":
            let value = { (label: String) in SwiftAppRenderer.number(argument(arguments, label)) }
            let alignment = SwiftAppRenderer.alignment(argument(arguments, "alignment"))
            if value("width") != nil || value("height") != nil {
                return AnyView(view.frame(width: value("width"), height: value("height"), alignment: alignment))
            }
            return AnyView(view.frame(
                minWidth: value("minWidth"), maxWidth: value("maxWidth"),
                minHeight: value("minHeight"), maxHeight: value("maxHeight"), alignment: alignment
            ))
        case "cornerRadius":
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: SwiftAppRenderer.number(first) ?? 0, style: .continuous)))
        case "clipShape":
            guard let shape = SwiftAppRenderer.shape(first) else { return view }
            return AnyView(view.clipShape(shape))
        case "opacity": return AnyView(view.opacity((try? first?.asDouble()) ?? 1))
        case "scaleEffect": return AnyView(view.scaleEffect(SwiftAppRenderer.number(first) ?? 1))
        case "rotationEffect":
            if case .member(let unit, let values)? = first, let amount = values?.first?.value, let number = try? amount.asDouble() {
                return AnyView(view.rotationEffect(unit == "radians" ? .radians(number) : .degrees(number)))
            }
            return view
        case "shadow":
            return AnyView(view.shadow(
                color: SwiftAppRenderer.color(argument(arguments, "color")) ?? .black.opacity(0.2),
                radius: SwiftAppRenderer.number(argument(arguments, "radius")) ?? 4,
                x: SwiftAppRenderer.number(argument(arguments, "x")) ?? 0,
                y: SwiftAppRenderer.number(argument(arguments, "y")) ?? 0
            ))
        case "offset":
            return AnyView(view.offset(x: SwiftAppRenderer.number(argument(arguments, "x")) ?? 0, y: SwiftAppRenderer.number(argument(arguments, "y")) ?? 0))
        case "blur": return AnyView(view.blur(radius: SwiftAppRenderer.number(argument(arguments, "radius")) ?? 0))
        case "navigationTitle": return AnyView(SwiftAppNavigationTitle(content: view, title: text(first)))
        case "navigationBarTitleDisplayMode":
            if case .member("inline", _)? = first { return AnyView(view.navigationBarTitleDisplayMode(.inline)) }
            return AnyView(view.navigationBarTitleDisplayMode(.large))
        case "buttonStyle":
            guard case .member(let style, _)? = first else { return view }
            switch style {
            case "borderedProminent": return AnyView(view.buttonStyle(.borderedProminent))
            case "bordered": return AnyView(view.buttonStyle(.bordered))
            case "borderless": return AnyView(view.buttonStyle(.borderless))
            case "plain": return AnyView(view.buttonStyle(.plain))
            case "glass": return AnyView(view.buttonStyle(.glass))
            case "glassProminent": return AnyView(view.buttonStyle(.glassProminent))
            default: return view
            }
        case "controlSize":
            guard case .member(let size, _)? = first else { return view }
            return AnyView(view.controlSize(size == "large" ? .large : size == "small" ? .small : size == "mini" ? .mini : .regular))
        case "textFieldStyle":
            if case .member("roundedBorder", _)? = first { return AnyView(view.textFieldStyle(.roundedBorder)) }
            return AnyView(view.textFieldStyle(.plain))
        case "listStyle":
            guard case .member(let style, _)? = first else { return view }
            switch style {
            case "plain": return AnyView(view.listStyle(.plain))
            case "grouped": return AnyView(view.listStyle(.grouped))
            case "inset": return AnyView(view.listStyle(.inset))
            case "sidebar": return AnyView(view.listStyle(.sidebar))
            default: return AnyView(view.listStyle(.insetGrouped))
            }
        case "pickerStyle":
            guard case .member(let style, _)? = first else { return view }
            switch style {
            case "segmented": return AnyView(view.pickerStyle(.segmented))
            case "wheel": return AnyView(view.pickerStyle(.wheel))
            case "inline": return AnyView(view.pickerStyle(.inline))
            default: return AnyView(view.pickerStyle(.menu))
            }
        case "multilineTextAlignment":
            guard case .member(let alignment, _)? = first else { return view }
            return AnyView(view.multilineTextAlignment(alignment == "center" ? .center : alignment == "trailing" ? .trailing : .leading))
        case "lineLimit": return AnyView(view.lineLimit(((try? first?.asInt()) ?? nil).flatMap { $0 > 0 ? $0 : nil }))
        case "disabled": return AnyView(view.disabled((try? first?.asBool()) ?? true))
        case "labelsHidden": return AnyView(view.labelsHidden())
        case "imageScale":
            guard case .member(let scale, _)? = first else { return view }
            return AnyView(view.imageScale(scale == "large" ? .large : scale == "small" ? .small : .medium))
        case "ignoresSafeArea": return AnyView(view.ignoresSafeArea())
        case "contentTransition": return AnyView(view.contentTransition(.numericText()))
        case "animation":
            let value = argument(arguments, "value")?.resolved.debugDisplay ?? ""
            return AnyView(view.animation(SwiftAppRenderer.animation(first), value: value))
        case "onAppear":
            guard let action = arguments.last?.value else { return view }
            return AnyView(view.onAppear { runtime.perform(action) })
        case "onTapGesture":
            guard let action = arguments.last?.value else { return view }
            let count = min(max(1, ((try? argument(arguments, "count")?.asInt()) ?? nil) ?? 1), 10)
            return AnyView(view.onTapGesture(count: count) { runtime.perform(action) })
        case "onChange":
            guard let action = arguments.last?.value else { return view }
            let value = argument(arguments, "of")?.resolved.debugDisplay ?? ""
            return AnyView(view.onChange(of: value) { runtime.perform(action) })
        case "onReceive":
            guard case .timer(let timer)? = first?.resolved,
                  timer.autoconnected,
                  let action = arguments.last?.value else { return view }
            return AnyView(SwiftAppTimerReceiver(
                runtime: runtime,
                interval: timer.interval,
                action: action,
                content: view
            ))
        case "sheet":
            guard case .binding(let binding)? = argument(arguments, "isPresented") else { return view }
            let content = arguments.last?.value
            return AnyView(view.sheet(isPresented: boolBinding(binding)) { SwiftAppPresentedContent(runtime: runtime, value: content) })
        case "alert":
            guard case .binding(let binding)? = argument(arguments, "isPresented") else { return view }
            let actions = arguments.first(where: { $0.label == nil && { if case .closure = $0.value { true } else { false } }($0) })?.value
            let message = argument(arguments, "message")
            return AnyView(view.alert(text(first), isPresented: boolBinding(binding)) {
                SwiftAppLazyContent(runtime: runtime, value: actions)
            } message: {
                SwiftAppLazyContent(runtime: runtime, value: message)
            })
        case "toolbar":
            guard let content = arguments.last?.value else { return view }
            let items = SwiftAppRenderer.flattenGroups(try runtime.renderContent(content))
            let leading = items.filter { item in
                guard case .member(let placement, _)? = item.argument("placement") else { return false }
                return ["topBarLeading", "navigationBarLeading", "cancellationAction"].contains(placement)
            }
            let trailing = items.filter { item in !leading.contains(where: { $0.name == item.name && $0.arguments.count == item.arguments.count }) }
            return AnyView(view.toolbar {
                ToolbarItemGroup(placement: .topBarLeading) { SwiftAppNodesView(runtime: runtime, nodes: leading) }
                ToolbarItemGroup(placement: .topBarTrailing) { SwiftAppNodesView(runtime: runtime, nodes: trailing) }
            })
        case "swipeActions":
            guard let content = arguments.last?.value else { return view }
            return AnyView(view.swipeActions { SwiftAppLazyContent(runtime: runtime, value: content) })
        case "searchable":
            guard case .binding(let binding)? = argument(arguments, "text") else { return view }
            return AnyView(view.searchable(text: stringBinding(binding)))
        case "environmentObject":
            guard case .object(let object)? = first?.resolved else { return view }
            return AnyView(view.transformEnvironment(\.swiftAppEnvironmentObjects) { $0[object.typeName] = .object(object) })
        case "tabItem":
            let content = arguments.last?.value
            return AnyView(view.tabItem { SwiftAppLazyContent(runtime: runtime, value: content) })
        case "badge":
            guard let value = first?.resolved else { return view }
            if case .int(let count) = value { return AnyView(view.badge(count)) }
            return AnyView(view.badge(Text(verbatim: value.display)))
        case "id": return AnyView(view.id(first?.resolved.debugDisplay ?? ""))
        case "accessibilityIdentifier": return AnyView(view.accessibilityIdentifier(text(first)))
        case "accessibilityLabel": return AnyView(view.accessibilityLabel(Text(verbatim: text(first))))
        default:
            // Layout-neutral or unsupported modifiers are ignored so a mostly
            // supported app still runs.
            return view
        }
    }
}

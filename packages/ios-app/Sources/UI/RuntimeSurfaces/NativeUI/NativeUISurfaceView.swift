import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Shared production host for persistent settings, transient sheets, and
/// Surface Lab. Every path uses the same controller, validator, and renderer.
struct NativeUISurfaceView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var controller: NativeUISurfaceController
    private let dismissTransientOnDisappear: Bool
    private let presentsAsSheet: Bool
    private let onTreeChange: (@MainActor (NativeUISurfaceTree) -> Void)?

    init(
        repository: any NativeUIRepository,
        request: NativeUISurfaceRequest,
        cacheNamespace: String,
        dismissTransientOnDisappear: Bool = false,
        presentsAsSheet: Bool = false,
        onTreeChange: (@MainActor (NativeUISurfaceTree) -> Void)? = nil
    ) {
        self.dismissTransientOnDisappear = dismissTransientOnDisappear
        self.presentsAsSheet = presentsAsSheet
        self.onTreeChange = onTreeChange
        _controller = State(initialValue: NativeUISurfaceController(
            repository: repository,
            request: request,
            cacheNamespace: cacheNamespace
        ))
    }

    var body: some View {
        Group {
            if presentsAsSheet {
                NavigationStack {
                    surfaceContent
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                SheetTitle(title: presentation.title, color: .cyan)
                            }
                            if presentation.showsDismiss {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button {
                                        Task { await controller.dismiss() }
                                    } label: {
                                        Image(systemName: "checkmark")
                                            .font(TronTypography.buttonSM)
                                            .foregroundStyle(.cyan)
                                    }
                                    .accessibilityLabel("Dismiss \(presentation.title)")
                                }
                            }
                        }
                }
                .adaptivePresentationDetents(presentationDetents, ipadSizing: .largeForm)
            } else {
                surfaceContent
            }
        }
        .task {
            controller.bridge.dismiss = { dismiss() }
            controller.bridge.navigate = { destination in
                guard let url = URL(string: destination),
                      dependencies.deepLinkRouter.handle(url: url)
                else { throw NativeUIClientBridge.BridgeError.unsupported("navigate") }
                return .object(["destination": .string(destination)])
            }
            await controller.start()
        }
        .sheet(
            item: pendingRequestBinding,
            onDismiss: {
                if controller.bridge.pendingRequest != nil { controller.bridge.cancel() }
            },
            content: pickerContent
        )
        .onDisappear {
            guard dismissTransientOnDisappear else { return }
            Task { await controller.dismiss() }
        }
        .onChange(of: controller.tree) { _, tree in
            if let tree { onTreeChange?(tree) }
        }
    }

    private var presentation: NativeUIPresentationDTO {
        controller.snapshot?.presentation
            ?? (try? NativeUIBundledDefinitions.load(controller.request.definitionId).presentation)
            ?? NativeUIPresentationDTO(title: "Details", detents: ["medium", "large"], showsDismiss: true)
    }

    private var presentationDetents: Set<PresentationDetent> {
        let detents = presentation.detents.compactMap { value -> PresentationDetent? in
            switch value {
            case "medium": .medium
            case "large": .large
            case "small": .fraction(0.28)
            default: nil
            }
        }
        return Set(detents).isEmpty ? [.medium, .large] : Set(detents)
    }

    private var surfaceContent: some View {
        Group {
            if let tree = controller.tree, tree.root != nil {
                NativeUIRenderer(controller: controller)
            } else {
                statusView
            }
        }
        .overlay(alignment: .topTrailing) {
            if case .fallback = controller.status {
                Image(systemName: "bolt.horizontal.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .padding(8)
                    .accessibilityLabel("Showing last known good native UI")
            }
        }
    }

    private var pendingRequestBinding: Binding<NativeUIClientBridge.Request?> {
        Binding(
            get: { controller.bridge.pendingRequest },
            set: { request in
                if request == nil, controller.bridge.pendingRequest != nil {
                    controller.bridge.cancel()
                }
            }
        )
    }

    @ViewBuilder
    private func pickerContent(_ request: NativeUIClientBridge.Request) -> some View {
        switch request.name {
        case "resourcePicker":
            if request.arguments["kind"]?.stringValue == "model" {
                ModelPickerSheet(
                    models: dependencies.modelRepository.cachedModels,
                    currentModelId: request.arguments["selected"]?.stringValue ?? "",
                    onSelect: { model in
                        controller.bridge.complete(.object(["value": .string(model.id)]))
                    }
                )
            } else {
                WorkspaceSelector(
                    selectedPath: Binding(
                        get: { request.arguments["selected"]?.stringValue ?? "" },
                        set: { path in
                            controller.bridge.complete(.object(["value": .string(path)]))
                        }
                    ),
                    connectionRepository: dependencies.connectionRepository,
                    workspaceBrowserRepository: dependencies.workspaceBrowserRepository
                )
            }
        case "filePicker":
            DocumentPicker { data, mimeType, fileName in
                completeFile(data: data, mimeType: mimeType, fileName: fileName)
            }
        case "camera":
            CameraCaptureSheet { image in
                guard let data = image.jpegData(compressionQuality: 0.88) else {
                    controller.bridge.cancel()
                    return
                }
                completeFile(data: data, mimeType: "image/jpeg", fileName: "capture.jpg")
            }
        default:
            ContentUnavailableView(
                "Function unavailable",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func completeFile(data: Data, mimeType: String, fileName: String?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-native-ui", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let safeName = (fileName ?? UUID().uuidString)
                .replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
            try data.write(to: url, options: .atomic)
            controller.bridge.complete(.object([
                "url": .string(url.absoluteString),
                "name": .string(fileName ?? url.lastPathComponent),
                "mimeType": .string(mimeType),
                "size": .number(Double(data.count)),
            ]))
        } catch {
            controller.bridge.cancel()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.status {
        case .idle, .loading:
            ProgressView().tint(.tronEmerald).frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            ContentUnavailableView(
                "Surface unavailable",
                systemImage: "rectangle.slash",
                description: Text(message)
            )
        case .deleted:
            EmptyView()
        case .ready, .fallback:
            ContentUnavailableView("Surface unavailable", systemImage: "rectangle.slash")
        }
    }
}

struct NativeUIRenderer: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    let controller: NativeUISurfaceController

    var body: some View {
        if let tree = controller.tree {
            component("root", in: tree)
        }
    }

    private func component(_ id: String, in tree: NativeUISurfaceTree) -> AnyView {
        guard let component = tree.components[id], isVisible(component, tree: tree) else {
            return AnyView(EmptyView())
        }
        let base = baseView(component, tree: tree)
        return applyModifiers(component.properties["modifiers"], to: base)
    }

    private func baseView(_ item: NativeUIComponentDTO, tree: NativeUISurfaceTree) -> AnyView {
        switch item.component {
        case "Surface":
            return item.properties["child"]?.stringValue.map { component($0, in: tree) }
                ?? AnyView(EmptyView())
        case "Navigation":
            let child = item.properties["child"]?.stringValue ?? ""
            let title = string(item.properties["title"], tree: tree) ?? ""
            return AnyView(component(child, in: tree).navigationTitle(title))
        case "Scroll":
            let child = item.properties["child"]?.stringValue ?? ""
            if controller.request.definitionId == "settings.engine"
                || controller.request.definitionId == "lab.catalog" {
                return component(child, in: tree)
            }
            let axis: Axis.Set = item.properties["axis"]?.stringValue == "horizontal" ? .horizontal : .vertical
            let shows = item.properties["showsIndicators"]?.boolValue ?? true
            return AnyView(ScrollView(axis, showsIndicators: shows) { component(child, in: tree) })
        case "Row":
            return AnyView(HStack(
                alignment: verticalAlignment(item.properties["alignment"]?.stringValue),
                spacing: spacing(item)
            ) { children(item, tree: tree) })
        case "Column", "List":
            return AnyView(LazyVStack(
                alignment: horizontalAlignment(item.properties["alignment"]?.stringValue),
                spacing: spacing(item)
            ) { children(item, tree: tree) })
        case "Overlay":
            return AnyView(ZStack(alignment: alignment(item.properties["alignment"]?.stringValue)) {
                children(item, tree: tree)
            })
        case "Grid":
            let count = max(1, min(8, Int(item.properties["columns"]?.numberValue ?? 2)))
            return AnyView(LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing(item)), count: count),
                spacing: spacing(item)
            ) { children(item, tree: tree) })
        case "AdaptiveColumns":
            let minimum = max(120, min(800, item.properties["minimumColumnWidth"]?.numberValue ?? 280))
            return AnyView(LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing(item))],
                alignment: .leading,
                spacing: spacing(item)
            ) { children(item, tree: tree) })
        case "Section":
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                if let title = string(item.properties["title"], tree: tree), !title.isEmpty {
                    SettingsSectionHeader(title: title)
                }
                children(item, tree: tree)
                if let footer = string(item.properties["footer"], tree: tree), !footer.isEmpty {
                    SettingsCaption(text: footer)
                }
            })
        case "GlassCard":
            return AnyView(SettingsCard(
                accent: color(item.properties["accent"]?.stringValue),
                interactive: item.properties["interactive"]?.boolValue ?? false
            ) { children(item, tree: tree) })
        case "Divider":
            if item.properties["orientation"]?.stringValue == "vertical" {
                return AnyView(Divider().frame(maxHeight: .infinity))
            }
            return AnyView(SettingsRowDivider())
        case "Spacer":
            let minimum = item.properties["minimumLength"].flatMap(\.numberValue).map { CGFloat($0) }
            return AnyView(Spacer(minLength: minimum))
        case "Text":
            return textView(item, tree: tree)
        case "Image":
            return imageView(item, tree: tree)
        case "Icon":
            return AnyView(Image(systemName: string(item.properties["systemName"], tree: tree) ?? "questionmark")
                .font(TronTypography.sans(size: item.properties["size"]?.numberValue ?? TronTypography.sizeBody))
                .foregroundStyle(color(item.properties["tone"]?.stringValue)))
        case "Badge":
            return AnyView(Text(string(item.properties["text"], tree: tree) ?? "")
                .font(TronTypography.badge)
                .foregroundStyle(color(item.properties["tone"]?.stringValue))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .glassEffect(.regular.tint(color(item.properties["tone"]?.stringValue).opacity(0.18)), in: Capsule()))
        case "Progress":
            let value = number(item.properties["value"], tree: tree) ?? 0
            let total = max(0.0001, number(item.properties["total"], tree: tree) ?? 1)
            return AnyView(ProgressView(value: value, total: total) {
                if let label = string(item.properties["label"], tree: tree) { Text(label) }
            }.tint(.tronEmerald))
        case "EmptyState":
            return AnyView(ContentUnavailableView(
                string(item.properties["title"], tree: tree) ?? "No content",
                systemImage: string(item.properties["systemImage"], tree: tree) ?? "rectangle",
                description: Text(string(item.properties["message"], tree: tree) ?? "")
            ))
        case "Button":
            return AnyView(NativeUIButton(item: item, tree: tree, controller: controller))
        case "Toggle":
            return AnyView(NativeUIToggle(item: item, tree: tree, controller: controller))
        case "Slider":
            return AnyView(NativeUISlider(item: item, tree: tree, controller: controller))
        case "Stepper":
            return AnyView(NativeUIStepper(item: item, tree: tree, controller: controller))
        case "TextField", "SecureField":
            return AnyView(NativeUITextField(
                item: item,
                tree: tree,
                controller: controller,
                secure: item.component == "SecureField"
            ))
        case "ChoicePicker":
            return AnyView(NativeUIChoicePicker(item: item, tree: tree, controller: controller))
        case "Menu":
            return AnyView(Menu {
                ForEach(childIds(item), id: \.self) { component($0, in: tree) }
            } label: {
                Label(
                    string(item.properties["label"], tree: tree) ?? "Menu",
                    systemImage: string(item.properties["icon"], tree: tree) ?? "ellipsis.circle"
                )
            })
        case "ResourcePicker":
            return AnyView(NativeUIButton(item: item, tree: tree, controller: controller))
        case "NativeSlot":
            let name = string(item.properties["name"], tree: tree) ?? ""
            return AnyView(nativeSlot(name))
        default:
            return AnyView(EmptyView())
        }
    }

    @ViewBuilder
    private func children(_ item: NativeUIComponentDTO, tree: NativeUISurfaceTree) -> some View {
        ForEach(childIds(item), id: \.self) { component($0, in: tree) }
    }

    private func childIds(_ item: NativeUIComponentDTO) -> [String] {
        item.properties["children"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func textView(_ item: NativeUIComponentDTO, tree: NativeUISurfaceTree) -> AnyView {
        let text = string(item.properties["text"], tree: tree) ?? ""
        let style = item.properties["style"]?.stringValue
        let value = Text(text)
            .font(style == "code" ? TronTypography.codeContent : style == "caption" ? TronTypography.caption : TronTypography.body)
            .foregroundStyle(style == "caption" ? Color.tronTextSecondary : Color.tronTextPrimary)
        let rendered: AnyView = item.properties["selectable"]?.boolValue == true
            ? AnyView(value.textSelection(.enabled)) : AnyView(value)
        if let label = string(item.properties["label"], tree: tree) {
            return AnyView(SettingsRow(
                icon: string(item.properties["icon"], tree: tree) ?? "text.alignleft",
                label: label
            ) { rendered.foregroundStyle(.tronEmerald) })
        }
        return rendered
    }

    private func imageView(_ item: NativeUIComponentDTO, tree: NativeUISurfaceTree) -> AnyView {
        if let urlString = string(item.properties["url"], tree: tree), let url = URL(string: urlString) {
            return AnyView(AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else if phase.error != nil { Image(systemName: "photo.badge.exclamationmark") }
                else { ProgressView() }
            })
        }
        return AnyView(Image(string(item.properties["name"], tree: tree) ?? "")
            .resizable().scaledToFit())
    }

    @ViewBuilder
    private func nativeSlot(_ name: String) -> some View {
        if name == "surfaceDiagnostics" {
            VStack(alignment: .leading, spacing: 4) {
                Label("Production renderer", systemImage: "checkmark.shield")
                Text("A2UI \(NativeUICatalog.a2uiVersion) • catalog r\(NativeUICatalog.revision)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
            .padding(12)
        }
    }

    private func isVisible(_ item: NativeUIComponentDTO, tree: NativeUISurfaceTree) -> Bool {
        tree.resolved(item.properties["visible"])?.boolValue ?? true
    }

    private func string(_ value: NativeUIJSONValue?, tree: NativeUISurfaceTree) -> String? {
        tree.resolved(value)?.stringValue
    }

    private func number(_ value: NativeUIJSONValue?, tree: NativeUISurfaceTree) -> Double? {
        tree.resolved(value)?.numberValue
    }

    private func spacing(_ item: NativeUIComponentDTO) -> CGFloat {
        item.properties["spacing"]?.numberValue ?? 12
    }

}

private struct NativeUIButton: View {
    let item: NativeUIComponentDTO
    let tree: NativeUISurfaceTree
    let controller: NativeUISurfaceController

    var body: some View {
        Button {
            Task { await controller.performAction(for: item) }
        } label: {
            SettingsRow(
                icon: item.properties["icon"]?.stringValue ?? "arrow.right.circle",
                label: item.properties["label"]?.stringValue ?? "Action"
            ) {
                if controller.activeActionIds.contains(item.id) {
                    ProgressView().controlSize(.small)
                } else if let value = tree.resolved(item.properties["value"])?.stringValue {
                    Text(value).foregroundStyle(.tronEmerald).lineLimit(1)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.tronTextMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.activeActionIds.contains(item.id))
        .accessibilityLabel(item.properties["accessibilityLabel"]?.stringValue ?? item.properties["label"]?.stringValue ?? "Action")
    }
}

private struct NativeUIToggle: View {
    let item: NativeUIComponentDTO
    let tree: NativeUISurfaceTree
    let controller: NativeUISurfaceController

    var body: some View {
        SettingsRow(
            icon: item.properties["icon"]?.stringValue ?? "switch.2",
            label: item.properties["label"]?.stringValue ?? "Toggle"
        ) {
            Toggle("", isOn: Binding(
                get: { tree.resolved(item.properties["value"])?.boolValue ?? false },
                set: { value in
                    controller.updateBoundValue(for: item, to: .bool(value))
                    Task { await controller.performAction(for: item, event: ["value": .bool(value)]) }
                }
            )).labelsHidden().tint(.tronEmerald)
        }
    }
}

private struct NativeUISlider: View {
    let item: NativeUIComponentDTO
    let tree: NativeUISurfaceTree
    let controller: NativeUISurfaceController

    var body: some View {
        let minimum = item.properties["minimum"]?.numberValue ?? 0
        let maximum = item.properties["maximum"]?.numberValue ?? 1
        let step = item.properties["step"]?.numberValue ?? 0.01
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    item.properties["label"]?.stringValue ?? "Value",
                    systemImage: item.properties["icon"]?.stringValue ?? "slider.horizontal.3"
                )
                Spacer()
                Text(formattedValue)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { tree.resolved(item.properties["value"])?.numberValue ?? minimum },
                set: { controller.updateBoundValue(for: item, to: .number($0)) }
            ), in: minimum...maximum, step: step) { editing in
                if !editing {
                    let value = controller.resolved(item.properties["value"])?.numberValue ?? minimum
                    Task { await controller.performAction(for: item, event: ["value": .number(value)]) }
                }
            }
            .tint(.tronEmerald)
        }
        .padding(12)
    }

    private var formattedValue: String {
        let value = tree.resolved(item.properties["value"])?.numberValue ?? 0
        if item.properties["format"]?.stringValue == "percent" { return "\(Int(value * 100))%" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

private struct NativeUIStepper: View {
    let item: NativeUIComponentDTO
    let tree: NativeUISurfaceTree
    let controller: NativeUISurfaceController

    var body: some View {
        let minimum = item.properties["minimum"]?.numberValue ?? 0
        let maximum = item.properties["maximum"]?.numberValue ?? 100
        let step = item.properties["step"]?.numberValue ?? 1
        SettingsRow(
            icon: item.properties["icon"]?.stringValue ?? "plusminus",
            label: item.properties["label"]?.stringValue ?? "Count"
        ) {
            Text(Int(value).description).foregroundStyle(.tronEmerald).monospacedDigit()
            Stepper("", value: Binding(
                get: { value },
                set: { newValue in
                    controller.updateBoundValue(for: item, to: .number(newValue))
                    Task { await controller.performAction(for: item, event: ["value": .number(newValue)]) }
                }
            ), in: minimum...maximum, step: step).labelsHidden()
        }
    }

    private var value: Double { tree.resolved(item.properties["value"])?.numberValue ?? 0 }
}

private struct NativeUITextField: View {
    let item: NativeUIComponentDTO
    let tree: NativeUISurfaceTree
    let controller: NativeUISurfaceController
    let secure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.properties["label"]?.stringValue ?? "Value").font(TronTypography.caption)
            Group {
                if secure {
                    SecureField(item.properties["placeholder"]?.stringValue ?? "", text: binding)
                } else {
                    TextField(item.properties["placeholder"]?.stringValue ?? "", text: binding)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                Task { await controller.performAction(for: item, event: ["value": .string(binding.wrappedValue)]) }
            }
        }
        .padding(12)
    }

    private var binding: Binding<String> {
        Binding(
            get: { tree.resolved(item.properties["value"])?.stringValue ?? "" },
            set: { controller.updateBoundValue(for: item, to: .string($0)) }
        )
    }
}

private struct NativeUIChoicePicker: View {
    let item: NativeUIComponentDTO
    let tree: NativeUISurfaceTree
    let controller: NativeUISurfaceController

    var body: some View {
        Picker(item.properties["label"]?.stringValue ?? "Choice", selection: Binding(
            get: { tree.resolved(item.properties["value"])?.stringValue ?? "" },
            set: { value in
                controller.updateBoundValue(for: item, to: .string(value))
                Task { await controller.performAction(for: item, event: ["value": .string(value)]) }
            }
        )) {
            ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
        }
        .pickerStyle(.menu)
        .padding(12)
    }

    private var options: [(label: String, value: String)] {
        item.properties["options"]?.arrayValue?.compactMap { raw in
            guard let object = raw.objectValue,
                  let label = object["label"]?.stringValue,
                  let value = object["value"]?.stringValue
            else { return nil }
            return (label, value)
        } ?? []
    }
}

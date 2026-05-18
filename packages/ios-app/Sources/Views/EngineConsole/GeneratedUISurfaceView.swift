import SwiftUI

enum GeneratedUIRendererStatus: Equatable {
    case renderable
    case closedError(String)
    case stale(String)
    case expired
    case damaged(String)
}

struct GeneratedUIRendererState: Equatable {
    var status: GeneratedUIRendererStatus
    var actionsEnabled: Bool
}

enum GeneratedUIRenderer {
    static let catalogId = "tron.ui.catalog.core.v1"
    static let catalogRevision: UInt64 = 1
    static let supportedComponents: Set<String> = [
        "Text", "Heading", "Monospace", "Badge", "Section", "List", "Table",
        "Tabs", "Disclosure", "ResourceRef", "InvocationRef", "GrantRef",
        "WorkerRef", "Metric", "TextField", "TextArea", "Select", "Toggle",
        "Stepper", "DateTime", "Button", "ButtonGroup", "Confirmation",
        "Progress", "Health", "Warning", "Error", "EmptyState"
    ]

    static func validate(
        surface: UiSurfaceDTO,
        resourceRef: UiSurfaceRefDTO? = nil,
        observedVersionId: String? = nil,
        now: Date = Date(),
        isOfflineCached: Bool = false
    ) -> GeneratedUIRendererState {
        guard surface.catalog.id == catalogId, surface.catalog.revision == catalogRevision else {
            return .init(status: .closedError("Unsupported UI catalog"), actionsEnabled: false)
        }
        if let lifecycle = resourceRef?.lifecycle,
           ["damaged", "discarded"].contains(lifecycle) {
            return .init(status: .damaged(lifecycle), actionsEnabled: false)
        }
        if let observedVersionId,
           let versionId = resourceRef?.versionId,
           observedVersionId != versionId {
            return .init(status: .stale(versionId), actionsEnabled: false)
        }
        if isExpired(surface.expiresAt, now: now) {
            return .init(status: .expired, actionsEnabled: false)
        }
        if let unsupported = firstUnsupportedComponent(surface.layout) {
            return .init(status: .closedError("Unsupported UI component: \(unsupported)"), actionsEnabled: false)
        }
        if surface.actions.contains(where: { isExpired($0.expiresAt, now: now) }) {
            return .init(status: .closedError("Surface contains expired action"), actionsEnabled: false)
        }
        return .init(status: .renderable, actionsEnabled: !isOfflineCached)
    }

    private static func firstUnsupportedComponent(_ component: UiComponentDTO) -> String? {
        guard supportedComponents.contains(component.type) else { return component.type }
        for child in component.children ?? [] {
            if let unsupported = firstUnsupportedComponent(child) {
                return unsupported
            }
        }
        return nil
    }

    private static func isExpired(_ value: String, now: Date) -> Bool {
        ISO8601DateFormatter().date(from: value).map { $0 <= now } ?? true
    }
}

struct GeneratedUISurfaceView: View {
    let surface: UiSurfaceDTO
    var resourceRef: UiSurfaceRefDTO?
    var observedVersionId: String?
    var isOfflineCached: Bool = false
    var onSubmit: (UiActionSubmissionDTO) -> Void = { _ in }

    @State private var formValues: [String: AnyCodable] = [:]

    var body: some View {
        renderedBody
    }

    private var renderedBody: AnyView {
        let state = GeneratedUIRenderer.validate(
            surface: surface,
            resourceRef: resourceRef,
            observedVersionId: observedVersionId,
            isOfflineCached: isOfflineCached
        )
        switch state.status {
        case .renderable:
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                renderComponent(surface.layout, actionsEnabled: state.actionsEnabled)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous)))
        case .closedError(let message):
            return AnyView(GeneratedUIClosedState(symbol: "exclamationmark.triangle", title: "Unsupported Surface", message: message))
        case .stale:
            return AnyView(GeneratedUIClosedState(symbol: "clock.arrow.circlepath", title: "Stale Surface", message: "Refresh before submitting actions."))
        case .expired:
            return AnyView(GeneratedUIClosedState(symbol: "timer", title: "Expired Surface", message: "Refresh before submitting actions."))
        case .damaged(let lifecycle):
            return AnyView(GeneratedUIClosedState(symbol: "xmark.octagon", title: "Unavailable Surface", message: lifecycle))
        }
    }

    private func renderComponent(_ component: UiComponentDTO, actionsEnabled: Bool) -> AnyView {
        switch component.type {
        case "Text":
            return AnyView(Text(component.props?.string("text") ?? ""))
        case "Heading":
            return AnyView(Text(component.props?.string("text") ?? "").font(.headline))
        case "Monospace":
            return AnyView(Text(component.props?.string("text") ?? "")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled))
        case "Badge":
            return AnyView(Text(component.props?.string("text") ?? "")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14), in: Capsule()))
        case "Section":
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                if let title = component.props?.string("title") {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                renderChildren(component, actionsEnabled: actionsEnabled)
            })
        case "List":
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(arrayStrings(component.props?["items"]), id: \.self) { item in
                    Label(item, systemImage: "smallcircle.filled.circle")
                }
            })
        case "Table":
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(arrayDictionaries(component.props?["rows"]).indices, id: \.self) { index in
                    Text(rowPreview(arrayDictionaries(component.props?["rows"])[index]))
                        .font(.caption.monospaced())
                }
            })
        case "Tabs", "Disclosure":
            return AnyView(DisclosureGroup(component.props?.string("title") ?? component.type) {
                renderChildren(component, actionsEnabled: actionsEnabled)
            })
        case "ResourceRef":
            return AnyView(referenceRow("Resource", value: component.props?.string("resourceId")))
        case "InvocationRef":
            return AnyView(referenceRow("Invocation", value: component.props?.string("invocationId")))
        case "GrantRef":
            return AnyView(referenceRow("Grant", value: component.props?.string("grantId")))
        case "WorkerRef":
            return AnyView(referenceRow("Worker", value: component.props?.string("workerId")))
        case "Metric":
            return AnyView(HStack {
                Text(component.props?.string("label") ?? "Metric")
                Spacer()
                Text(component.props?["value"]?.stringValue ?? "\(component.props?["value"]?.value ?? "")")
                    .font(.headline.monospacedDigit())
            })
        case "TextField":
            return AnyView(TextField(
                component.props?.string("label") ?? "",
                text: binding(for: component.props?.string("name") ?? component.id ?? "field")
            )
            .textFieldStyle(.roundedBorder))
        case "TextArea":
            return AnyView(TextEditor(text: binding(for: component.props?.string("name") ?? component.id ?? "text"))
                .frame(minHeight: 88)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2))))
        case "Select":
            return AnyView(Picker(component.props?.string("label") ?? "", selection: binding(for: component.props?.string("name") ?? component.id ?? "select")) {
                ForEach(arrayStrings(component.props?["options"]), id: \.self) { option in
                    Text(option).tag(option)
                }
            })
        case "Toggle":
            return AnyView(Toggle(
                component.props?.string("label") ?? "",
                isOn: boolBinding(for: component.props?.string("name") ?? component.id ?? "toggle")
            ))
        case "Stepper":
            return AnyView(Stepper(component.props?.string("label") ?? "", value: intBinding(for: component.props?.string("name") ?? component.id ?? "stepper")))
        case "DateTime":
            return AnyView(TextField(
                component.props?.string("label") ?? "Date",
                text: binding(for: component.props?.string("name") ?? component.id ?? "datetime")
            )
            .textFieldStyle(.roundedBorder))
        case "Button":
            return AnyView(Button(component.props?.string("label") ?? "Action") {
                submit(actionId: component.props?.string("actionId"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!actionsEnabled))
        case "ButtonGroup":
            return AnyView(HStack {
                ForEach(arrayStrings(component.props?["actions"]), id: \.self) { actionId in
                    Button(actionId) { submit(actionId: actionId) }
                        .buttonStyle(.bordered)
                        .disabled(!actionsEnabled)
                }
            })
        case "Confirmation":
            return AnyView(Button(component.props?.string("title") ?? "Confirm") {
                submit(actionId: component.props?.string("confirmActionId"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!actionsEnabled))
        case "Progress":
            return AnyView(ProgressView(value: component.props?["value"]?.doubleValue, total: component.props?["total"]?.doubleValue ?? 1))
        case "Health":
            return AnyView(Label(component.props?.string("label") ?? component.props?.string("status") ?? "Health", systemImage: "heart.text.square"))
        case "Warning":
            return AnyView(Label(component.props?.string("text") ?? "Warning", systemImage: "exclamationmark.triangle").foregroundStyle(.orange))
        case "Error":
            return AnyView(Label(component.props?.string("text") ?? "Error", systemImage: "xmark.octagon").foregroundStyle(.red))
        case "EmptyState":
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text(component.props?.string("title") ?? "Empty").font(.subheadline.weight(.semibold))
                Text(component.props?.string("message") ?? "").font(.caption).foregroundStyle(.secondary)
            })
        default:
            return AnyView(GeneratedUIClosedState(symbol: "exclamationmark.triangle", title: "Unsupported Surface", message: component.type))
        }
    }

    private func renderChildren(_ component: UiComponentDTO, actionsEnabled: Bool) -> AnyView {
        return AnyView(ForEach(Array((component.children ?? []).enumerated()), id: \.offset) { _, child in
            renderComponent(child, actionsEnabled: actionsEnabled)
        })
    }

    private func referenceRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "unknown").font(.caption.monospaced()).lineLimit(1)
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { formValues[key]?.stringValue ?? "" },
            set: { formValues[key] = AnyCodable($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { formValues[key]?.boolValue ?? false },
            set: { formValues[key] = AnyCodable($0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: { formValues[key]?.intValue ?? 0 },
            set: { formValues[key] = AnyCodable($0) }
        )
    }

    private func submit(actionId: String?) {
        guard let actionId,
              let resourceId = resourceRef?.resourceId,
              let versionId = resourceRef?.versionId
        else { return }
        onSubmit(
            UiActionSubmissionDTO(
                surfaceResourceId: resourceId,
                surfaceVersionId: versionId,
                actionId: actionId,
                userInput: formValues,
                idempotencyKey: UUID().uuidString
            )
        )
    }

    private func arrayStrings(_ value: AnyCodable?) -> [String] {
        value?.arrayValue?.compactMap { $0 as? String } ?? []
    }

    private func arrayDictionaries(_ value: AnyCodable?) -> [[String: Any]] {
        value?.arrayValue?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func rowPreview(_ row: [String: Any]) -> String {
        row.keys.sorted().map { "\($0): \(row[$0] ?? "")" }.joined(separator: "  ")
    }
}

private struct GeneratedUIClosedState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

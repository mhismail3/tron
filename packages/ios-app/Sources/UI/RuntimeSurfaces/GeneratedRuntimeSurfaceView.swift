import SwiftUI

struct GeneratedRuntimeSurfaceView: View {
    let surface: UiSurfaceDTO
    var resourceRef: UiSurfaceRefDTO?
    var observedVersionId: String?
    var isOfflineCached: Bool = false
    var onSubmit: (UiActionSubmissionDTO) -> Void = { _ in }

    @State private var formValues: [String: AnyCodable] = [:]
    @State private var seededSurfaceKey: String?
    @State private var expandedComponentIDs: Set<String> = []
    @State private var pendingConfirmation: GeneratedUIConfirmation?

    var body: some View {
        renderedBody
            .onAppear { seedFormDefaultsIfNeeded() }
            .onChange(of: surfaceSeedKey) { _, _ in
                seedFormDefaultsIfNeeded(reset: true)
            }
            .confirmationDialog(
                pendingConfirmation?.title ?? "Confirm Action",
                isPresented: confirmationDialogPresented,
                titleVisibility: .visible
            ) {
                if let pendingConfirmation {
                    Button(pendingConfirmation.confirmLabel, role: pendingConfirmation.buttonRole.dialogRole) {
                        let actionId = pendingConfirmation.actionId
                        self.pendingConfirmation = nil
                        submit(actionId: actionId)
                    }
                    Button("Cancel", role: .cancel) {
                        self.pendingConfirmation = nil
                    }
                }
            } message: {
                Text(pendingConfirmation?.message ?? "")
            }
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
            let content = renderComponent(surface.layout, actionsEnabled: state.actionsEnabled, isRoot: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            return AnyView(content
                .padding(12)
                .sectionFill(.tronEmerald, cornerRadius: 8, subtle: true, compact: false, interactive: false))
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

    private func renderComponent(_ component: UiComponentDTO, actionsEnabled: Bool, isRoot: Bool = false) -> AnyView {
        switch component.type {
        case "Text":
            return AnyView(Text(component.props?.string("text") ?? "")
                .font(TronTypography.body)
                .foregroundStyle(.tronTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading))
        case "Heading":
            return AnyView(Text(component.props?.string("text") ?? "")
                .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading))
        case "Monospace":
            return AnyView(Text(component.props?.string("text") ?? "")
                .font(TronTypography.codeContent)
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading))
        case "Badge":
            return AnyView(Text(component.props?.string("text") ?? "")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .sectionFill(.tronEmerald, cornerRadius: 999, subtle: true, compact: true, interactive: false))
        case "Section":
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                if let title = component.props?.string("title") {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                }
                renderChildren(component, actionsEnabled: actionsEnabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        case "List":
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(arrayStrings(component.props?["items"]), id: \.self) { item in
                    Label(item, systemImage: "circle.fill")
                        .font(TronTypography.body)
                        .foregroundStyle(.tronTextPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        case "Table":
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(arrayDictionaries(component.props?["rows"]).indices, id: \.self) { index in
                    Text(rowPreview(arrayDictionaries(component.props?["rows"])[index]))
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        case "Tabs", "Disclosure":
            return AnyView(disclosurePanel(component, actionsEnabled: actionsEnabled))
        case "ResourceRef":
            return AnyView(referenceRow("Resource", value: component.props?.string("resourceId")))
        case "InvocationRef":
            return AnyView(referenceRow("Invocation", value: component.props?.string("invocationId")))
        case "GrantRef":
            return AnyView(referenceRow("Grant", value: component.props?.string("grantId")))
        case "Metric":
            return AnyView(HStack {
                Text(component.props?.string("label") ?? "Metric")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(formattedValue(component.props?["value"]))
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.tronSurfaceElevated.opacity(0.34))
            ))
        case "TextField":
            return AnyView(tronTextField(
                label: component.props?.string("label"),
                placeholder: component.props?.string("label") ?? "",
                text: binding(for: component.props?.string("name") ?? component.id ?? "field")
            ))
        case "TextArea":
            return AnyView(tronTextArea(
                label: component.props?.string("label"),
                text: binding(for: component.props?.string("name") ?? component.id ?? "text")
            ))
        case "Select":
            return AnyView(SettingsCard(accent: .tronEmerald, interactive: false) {
                SettingsRow(icon: "line.3.horizontal.decrease.circle", label: component.props?.string("label") ?? "Select") {
                    Picker("", selection: binding(for: component.props?.string("name") ?? component.id ?? "select")) {
                        ForEach(arrayStrings(component.props?["options"]), id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
            })
        case "Toggle":
            return AnyView(SettingsCard(accent: .tronEmerald, interactive: false) {
                SettingsRow(icon: "switch.2", label: component.props?.string("label") ?? "Toggle") {
                    Toggle("", isOn: boolBinding(for: component.props?.string("name") ?? component.id ?? "toggle"))
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            })
        case "Stepper":
            let key = component.props?.string("name") ?? component.id ?? "stepper"
            return AnyView(SettingsCard(accent: .tronEmerald, interactive: false) {
                SettingsRow(icon: "number", label: component.props?.string("label") ?? "Value") {
                    Stepper(value: intBinding(for: key)) {
                        Text("\(formValues[key]?.intValue ?? 0)")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                    }
                }
            })
        case "DateTime":
            return AnyView(tronTextField(
                label: component.props?.string("label") ?? "Date",
                placeholder: component.props?.string("label") ?? "Date",
                text: binding(for: component.props?.string("name") ?? component.id ?? "datetime")
            ))
        case "Button":
            return generatedActionButton(
                actionId: component.props?.string("actionId"),
                componentLabel: component.props?.string("label"),
                actionsEnabled: actionsEnabled
            )
        case "ButtonGroup":
            return AnyView(HStack(spacing: 8) {
                ForEach(arrayStrings(component.props?["actions"]), id: \.self) { actionId in
                    generatedActionButton(
                        actionId: actionId,
                        componentLabel: nil,
                        actionsEnabled: actionsEnabled,
                        compact: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading))
        case "Confirmation":
            return confirmationButton(
                actionId: component.props?.string("confirmActionId"),
                title: component.props?.string("title") ?? "Confirm",
                message: component.props?.string("message") ?? "This action cannot be undone.",
                actionsEnabled: actionsEnabled
            )
        case "Progress":
            return AnyView(ProgressView(value: component.props?["value"]?.doubleValue, total: component.props?["total"]?.doubleValue ?? 1))
        case "Health":
            return AnyView(Label(component.props?.string("label") ?? component.props?.string("status") ?? "Health", systemImage: "heart.text.square")
                .font(TronTypography.body)
                .foregroundStyle(.tronSuccess))
        case "Warning":
            return AnyView(Label(component.props?.string("text") ?? "Warning", systemImage: "exclamationmark.triangle")
                .font(TronTypography.body)
                .foregroundStyle(.tronWarning))
        case "Error":
            return AnyView(Label(component.props?.string("text") ?? "Error", systemImage: "xmark.octagon")
                .font(TronTypography.body)
                .foregroundStyle(.tronError))
        case "EmptyState":
            return AnyView(VStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text(component.props?.string("title") ?? "Empty")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(component.props?.string("message") ?? "")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.tronSurfaceElevated.opacity(0.28))
            ))
        default:
            return AnyView(GeneratedUIClosedState(symbol: "exclamationmark.triangle", title: "Unsupported Surface", message: component.type))
        }
    }

    private func disclosurePanel(_ component: UiComponentDTO, actionsEnabled: Bool) -> some View {
        let expansion = expansionBinding(for: component.stableID)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(generatedUIRowExpansionAnimation) {
                    expansion.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: disclosureIcon(for: component))
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text(component.props?.string("title") ?? component.type)
                        .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 10)
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(expansion.wrappedValue ? 180 : 0))
                        .animation(generatedUIRowExpansionAnimation, value: expansion.wrappedValue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.noFeedback)

            if expansion.wrappedValue {
                Rectangle()
                    .fill(Color.tronBorder.opacity(0.45))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                renderChildren(component, actionsEnabled: actionsEnabled)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronSurfaceElevated.opacity(0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder.opacity(0.72), lineWidth: 1)
        )
    }

    private func renderChildren(_ component: UiComponentDTO, actionsEnabled: Bool) -> AnyView {
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((component.children ?? []).enumerated()), id: \.offset) { _, child in
                renderComponent(child, actionsEnabled: actionsEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading))
    }

    private func referenceRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextMuted)
            Spacer()
            Text(value ?? "unknown")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private func tronTextField(label: String?, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(.tronTextPrimary)
                .tint(.tronEmerald)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.tronSurface.opacity(0.88))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.tronBorder.opacity(0.78), lineWidth: 1)
                )
        }
    }

    private func tronTextArea(label: String?, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextEditor(text: text)
                .font(TronTypography.input)
                .foregroundStyle(.tronTextPrimary)
                .tint(.tronEmerald)
                .frame(minHeight: 104)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.tronSurface.opacity(0.84))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.tronBorder.opacity(0.78), lineWidth: 1)
                )
        }
    }

    private func fieldLabel(_ label: String?) -> some View {
        Text(label ?? "")
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(.tronTextSecondary)
            .opacity((label ?? "").isEmpty ? 0 : 1)
    }

    private func generatedActionButton(
        actionId: String?,
        componentLabel: String?,
        actionsEnabled: Bool,
        compact: Bool = false
    ) -> AnyView {
        let action = action(for: actionId)
        let label = action?.label ?? componentLabel ?? "Action"
        let role = GeneratedUIActionButtonRole(presentation: action?.presentation)
        let enabled = actionsEnabled && canSubmit(actionId: actionId)
        let button = Button {
            submit(actionId: actionId)
        } label: {
            Label(label, systemImage: presentationIcon(for: action))
                .font(TronTypography.buttonSM)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: compact ? nil : .infinity)
        }
        .disabled(!enabled)
        return AnyView(button.buttonStyle(.generatedUIAction(role: role, isEnabled: enabled, compact: compact)))
    }

    private func confirmationButton(
        actionId: String?,
        title: String,
        message: String,
        actionsEnabled: Bool
    ) -> AnyView {
        let action = action(for: actionId)
        let label = action?.label ?? title
        let role = GeneratedUIActionButtonRole(presentation: action?.presentation)
        let enabled = actionsEnabled && canSubmit(actionId: actionId)
        return AnyView(Button {
            guard let actionId, enabled else { return }
            pendingConfirmation = GeneratedUIConfirmation(
                actionId: actionId,
                title: title,
                message: message,
                confirmLabel: label,
                buttonRole: role
            )
        } label: {
            Label(title, systemImage: presentationIcon(for: action))
                .font(TronTypography.buttonSM)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.generatedUIAction(role: role, isEnabled: enabled))
        .disabled(!enabled))
    }

    private func action(for actionId: String?) -> UiActionDTO? {
        guard let actionId else { return nil }
        return surface.actions.first { $0.actionId == actionId }
    }

    private func canSubmit(actionId: String?) -> Bool {
        guard let action = action(for: actionId) else { return false }
        return GeneratedUIRenderer.inputIsSatisfied(formValues, for: action)
    }

    private var confirmationDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingConfirmation = nil
                }
            }
        )
    }

    private func expansionBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedComponentIDs.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedComponentIDs.insert(key)
                } else {
                    expandedComponentIDs.remove(key)
                }
            }
        )
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

    private var surfaceSeedKey: String {
        [
            resourceRef?.resourceId ?? surface.surfaceId,
            resourceRef?.versionId ?? "",
            "\(surface.schemaVersion)"
        ].joined(separator: ":")
    }

    private func seedFormDefaultsIfNeeded(reset: Bool = false) {
        guard reset || seededSurfaceKey != surfaceSeedKey else { return }
        formValues = [:]
        expandedComponentIDs = []
        seedFormDefaults(from: surface.layout)
        seededSurfaceKey = surfaceSeedKey
    }

    private func seedFormDefaults(from component: UiComponentDTO) {
        if ["Disclosure", "Tabs"].contains(component.type),
           component.props?.bool("open") == true {
            expandedComponentIDs.insert(component.stableID)
        }
        if ["TextField", "TextArea", "Select", "Toggle", "Stepper", "DateTime"].contains(component.type),
           let key = component.props?.string("name") ?? component.id,
           let value = component.props?["value"],
           !value.isNull {
            formValues[key] = value
        }
        for child in component.children ?? [] {
            seedFormDefaults(from: child)
        }
    }

    private func submit(actionId: String?) {
        guard !isOfflineCached else { return }
        guard let actionId,
              let action = action(for: actionId),
              GeneratedUIRenderer.inputIsSatisfied(formValues, for: action),
              let resourceId = resourceRef?.resourceId,
              let versionId = resourceRef?.versionId
        else { return }
        onSubmit(
            UiActionSubmissionDTO(
                surfaceResourceId: resourceId,
                surfaceVersionId: versionId,
                actionId: actionId,
                userInput: GeneratedUIRenderer.userInput(from: formValues, for: action),
                idempotencyKey: UUID().uuidString
            )
        )
    }
}

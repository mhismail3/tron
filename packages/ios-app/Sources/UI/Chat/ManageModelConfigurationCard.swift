import SwiftUI
import TronMobileCore

struct ManageModelConfigurationCard: View {
    static let keys: Set<String> = ["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow"]
    let sessionID: String
    var home = false
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @PresentationState private var sliderPresentation = ConfigurationSliderPresentation()
    @PresentationState private var changing = false
    @PresentationState private var error: String?
    @PresentationState private var pending: PendingReview?
    private struct PendingReview: Identifiable { let id = UUID(); let change: JSONValue; let review: ChangeReview }

    private var target: JSONValue {
        home ? .object(["kind": .string("home")]) : SettingsTarget.sessionGatewayTarget(sessionID)
    }
    private var snapshot: SettingsSnapshot? { model.settingsSnapshot(for: target) }
    private var ref: ResolvedSetting? { snapshot?.resolution.keys.first { $0.key == "model.ref[role=chat]" } }
    private var modelKey: String? {
        guard let value = ref?.value?.objectValue, let provider = value["provider"]?.stringValue,
              let id = value["id"]?.stringValue else { return nil }
        return "\(provider)/\(id)"
    }
    private var thinking: ResolvedSetting? { snapshot?.resolution.keys.first { $0.key == "model.thinking[role=chat]" } }
    private var contextWindow: ResolvedSetting? {
        snapshot?.resolution.keys.first { $0.key == "model.contextWindow" && $0.qualifiers?["model"] == modelKey }
    }
    private var availability: ModelSelectionAvailability {
        if changing { return .applying }
        if let reason = model.rendererConfigurationLockedReason(target: target) { return .blocked(reason) }
        return .ready
    }

    var body: some View {
        TronGlassCard(accent: .tronPrimary) {
            VStack(spacing: 0) {
                if let ref {
                    modelRow(ref)
                    if let thinking { TronSettingsDivider(); choiceRow(thinking, title: "Thinking", icon: "brain") }
                    if let contextWindow {
                        TronSettingsDivider()
                        choiceRow(contextWindow, title: "Context Window", icon: "gauge.with.dots.needle.50percent")
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronError)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                } else {
                    TronSheetLoadingState(label: "Loading model…")
                }
            }
        }
        .environment(\.tronPresentationDependencyRead, PresentationDependencyRead(
            id: .init(target: target, freshness: model.settingsFreshness),
            perform: { try? await model.refreshSettingsSnapshot(for: target) }))
        .tronConfigurationSliderHost(sliderPresentation)
        .tronManagedSheet(item: $pending, identity: { "manage.model.review.\($0.id)" }) { item in
            ChangeReviewSheet(review: item.review, approve: {
                guard pending?.id == item.id else { return }
                pending = nil
                commit(item.change, digest: item.review.digest)
            }, cancel: { pending = nil })
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(home ? "home-model-summary" : "session-model-summary")
        .task(id: PresentationActivityTaskID(source: model.settingsFreshness, presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            try? await model.refreshSettingsSnapshot(for: target)
        }
    }

    private func modelRow(_ setting: ResolvedSetting) -> some View {
        let value = setting.value?.objectValue
        let selected = model.providerCatalog(for: catalogTarget)?.models.first {
            $0.provider == value?["provider"]?.stringValue && $0.id == value?["id"]?.stringValue
        }
        return VStack(spacing: 0) {
            TronSettingsRow(icon: "cpu", title: selected?.displayName ?? setting.display, titleFont: SessionSummaryTypography.headline) {
                TronProgressiveSheetLink(accessibilityLabel: "Switch Model", identity: "manage.model.switch", detents: .contentFit) {
                    SettingsModelPicker(setting: setting, target: target, title: "Models", selectionAvailability: availability,
                                        onReset: setting.overridden == true ? { change(setting, nil) } : nil) { change(setting, $0) }
                } label: { TronInlineActionLabel("Switch Model") }
                .disabled(setting.projectSetting != nil)
                .accessibilityIdentifier("manage-model-switch")
                .accessibilityValue(availability.accessibilityValue)
            }
            .lineLimit(1)
            .environment(\.tronSettingsRowAccessory, resetAccessory(setting))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settingsRowIdentifier(setting))
    }

    private var catalogTarget: ProviderCatalogTarget { home ? .global : .session(id: sessionID) }

    private var selectedModel: ModelSummary? {
        guard let value = ref?.value?.objectValue, let provider = value["provider"]?.stringValue,
              let id = value["id"]?.stringValue else { return nil }
        return model.providerCatalog(for: catalogTarget)?.models.first { $0.provider == provider && $0.id == id }
    }

    private func choiceOptions(for setting: ResolvedSetting) -> [SettingsOption] {
        switch setting.key {
        case "model.thinking[role=chat]":
            return (model.sessionContextPresentation(for: sessionID)?.availableThinkingLevels ?? []).map {
                SettingsOption(value: .string($0), label: ThinkingLevelPresentation.title($0), detail: nil, disabledReason: nil, resource: nil)
            }
        case "model.contextWindow":
            guard let limits = selectedModel?.contextWindowLimits else { return [] }
            return Array(Set([limits.minimum, limits.`default`, limits.maximum])).sorted().map { tokens in
                SettingsOption(value: .number(Double(tokens)), label: tokens.isMultiple(of: 1_000) ? "\(tokens / 1_000)K tokens" : "\(tokens) tokens",
                               detail: nil, disabledReason: nil, resource: nil)
            }
        default:
            return []
        }
    }

    private func choiceRow(_ setting: ResolvedSetting, title: String, icon: String) -> some View {
        let options = choiceOptions(for: setting)
        return HStack(spacing: 0) {
            if options.isEmpty || setting.projectSetting != nil {
                TronSettingsRow(icon: icon, title: title) { TronInlineActionLabel(setting.display, accent: .tronPrimary) }
            } else {
                SettingsChoiceSelectionRow(title: title, icon: icon, value: setting.value ?? .null, display: setting.display,
                                           options: options, onChange: { change(setting, $0) })
                    .environment(\.configurationSliderPresentation, sliderPresentation)
            }
            if setting.overridden == true && setting.projectSetting == nil { resetButton(setting).padding(.trailing, 12) }
        }
        .disabled(!availability.canSelect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settingsRowIdentifier(setting))
    }

    private func resetAccessory(_ setting: ResolvedSetting) -> (@MainActor @Sendable () -> AnyView)? {
        guard setting.overridden == true, setting.projectSetting == nil else { return nil }
        let button = AnyView(resetButton(setting))
        return { button }
    }

    private func resetButton(_ setting: ResolvedSetting) -> some View {
        Button { TronHaptics.shared.play(.selectionChanged); change(setting, nil) } label: {
            TronInlineActionLabel("", icon: "arrow.uturn.backward", alignment: .leading, accent: .tronPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Revert")
        .accessibilityIdentifier("\(settingsRowIdentifier(setting))-reset")
        .disabled(!availability.canSelect)
    }

    private func change(_ setting: ResolvedSetting, _ value: JSONValue?) {
        guard availability.canSelect, activity.allowsDataPublication else { return }
        var object: [String: JSONValue] = ["key": .string(setting.key), "layer": .string("session"), "op": .string(value == nil ? "unset" : "set")]
        if let qualifiers = setting.qualifiers, !qualifiers.isEmpty { object["qualifiers"] = .object(qualifiers.mapValues(JSONValue.string)) }
        if let value { object["value"] = value }
        let change = JSONValue.object(object)
        let requestTarget = target
        changing = true
        Task { @MainActor in
            do {
                let preview = try await model.previewSettingsChange(target: requestTarget, change: change)
                if let failure = preview.changes.first?.error { error = failure.message; changing = false; return }
                if let review = preview.review, review.requiresTap { changing = false; pending = PendingReview(change: change, review: review); return }
                changing = false
                commit(change, digest: nil)
            } catch is CancellationError {
                changing = false
            } catch {
                changing = false
                self.error = error.localizedDescription
            }
        }
    }

    private func commit(_ change: JSONValue, digest: String?) {
        let requestTarget = target
        changing = true
        Task { @MainActor in
            defer { changing = false }
            do {
                try await model.changeSetting(target: requestTarget, change: change, confirmationDigest: digest)
                model.noteSettingsChanged()
                try? await model.refreshSettingsSnapshot(for: requestTarget)
                error = nil
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

func settingsRowIdentifier(_ setting: ResolvedSetting) -> String {
    "settings-row-" + String(setting.id.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" ? Character(scalar) : "_"
    })
}

struct SettingsModelPicker: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let title: String
    var selectionAvailability: ModelSelectionAvailability = .ready
    var onReset: (() -> Void)? = nil
    let onChoose: (JSONValue) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var catalogTarget: ProviderCatalogTarget {
        if target.objectValue?["kind"]?.stringValue == "session", let id = target.objectValue?["sessionId"]?.stringValue {
            return .session(id: id)
        }
        return .global
    }

    private var selection: Binding<ModelRef?> {
        Binding(
            get: {
                guard let value = setting.value?.objectValue, let provider = value["provider"]?.stringValue,
                      let id = value["id"]?.stringValue else { return nil }
                return ModelRef(provider: provider, id: id)
            },
            set: { ref in
                guard let ref, selectionAvailability.canSelect else { return }
                onChoose(.object(["provider": .string(ref.provider), "id": .string(ref.id)]))
                dismiss()
            }
        )
    }

    var body: some View {
        let models = model.providerCatalog(for: catalogTarget)?.models.filter(\.available)
        Group {
            if let models, models.isEmpty {
                TronPlaceholderState(title: "No Models", detail: "No available model can be used here.", icon: "cpu")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let models {
                ModelPicker(selection: selection, models: models, selectionAvailability: selectionAvailability)
            } else {
                TronSheetLoadingState(label: "Loading models…")
            }
        }
            .tronNavigationTitle(title)
            .toolbar {
                if let onReset {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            guard selectionAvailability.canSelect else { return }
                            onReset(); dismiss()
                        } label: {
                            Image(systemName: "arrow.uturn.backward").tronToolbarAction()
                        }
                        .accessibilityLabel("Reset to inherited")
                        .accessibilityIdentifier("\(settingsRowIdentifier(setting))-picker-reset")
                        .disabled(!selectionAvailability.canSelect)
                    }
                }
            }
            .task { await model.refreshProviders(target: catalogTarget) }
    }
}

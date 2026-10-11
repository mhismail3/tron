import SwiftUI
import TronMobileCore

/// Permissions › Floors: the maintainer's own floor per key (docs/settings-model.md
/// 5.4, 5.4a). Only this iPhone writes `permissions.floor`; agents cannot change
/// floors. Every row's words are Gateway text from `settings.resolve`.
struct PermissionFloorsSettingsView: View {
    private static let key = "permissions.floor"

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity

    @State private var floors: [ResolvedSetting]?
    @State private var loadError: String?
    @State private var loadGeneration = 0
    @State private var reloadTick = 0
    /// The row whose change is in flight or being previewed; its control is disabled.
    @State private var changingID: String?
    @State private var pendingLowering: PendingLowering?

    private struct PendingLowering {
        let change: JSONValue
        let rowID: String
        let message: String
    }

    /// Re-reads when the settings state, the foreground lane, or an accepted change moves.
    private struct FloorLoadID: Hashable {
        let invalidationGeneration: Int
        let foregroundGeneration: Int
        let reloadTick: Int
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let floors, !floors.isEmpty {
                    floorGroup(floors)
                } else if let loadError {
                    TronPlaceholderState(
                        title: "Permissions Unavailable",
                        detail: loadError,
                        icon: "hand.raised",
                        accent: .tronAmber,
                        actionTitle: "Reload",
                        action: reload
                    )
                    .frame(maxWidth: .infinity)
                } else if floors == nil {
                    TronLoadingState(label: "Loading permissions…", accent: .tronAmber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TronSettingsCaption("Lowering a floor needs your tap here; agents cannot change floors.")
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Permissions")
        .confirmationDialog(
            "Lower this floor?",
            isPresented: Binding(
                get: { pendingLowering != nil },
                set: { if !$0 { pendingLowering = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingLowering
        ) { lowering in
            Button("Lower floor") {
                pendingLowering = nil
                commit(lowering.change, rowID: lowering.rowID)
            }
            .accessibilityIdentifier("permission-floor-confirm")
            Button("Cancel", role: .cancel) { pendingLowering = nil }
        } message: { lowering in
            Text(lowering.message)
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { loadGeneration &+= 1 }
        }
        .onDisappear { loadGeneration &+= 1 }
        .task(id: PresentationActivityTaskID(
            source: FloorLoadID(
                invalidationGeneration: model.settingsInvalidationGeneration,
                foregroundGeneration: model.foregroundReconciliationGeneration,
                reloadTick: reloadTick
            ),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await load()
        }
    }

    private func floorGroup(_ floors: [ResolvedSetting]) -> some View {
        TronSettingsGroup(
            "Floors",
            detail: "The least attention an agent's change to each setting gets: Quiet applies it, Notify applies it and tells you, Approve waits for your tap. A turn that read web content raises it one step.",
            accent: .tronAmber
        ) {
            ForEach(Array(floors.enumerated()), id: \.element.id) { index, setting in
                if index > 0 { TronSettingsDivider(accent: .tronAmber) }
                floorRow(setting)
            }
        }
    }

    private func floorRow(_ setting: ResolvedSetting) -> some View {
        let layerLabel = setting.badge("layer")?.label
        return TronSelectionRow(
            icon: "hand.raised",
            title: setting.badge("scope")?.label ?? setting.qualifiers?["key"] ?? setting.key,
            detail: layerLabel,
            value: setting.display,
            accent: .tronAmber
        ) {
            Button("Quiet") { choose(setting, tier: "quiet") }
                .accessibilityIdentifier("permission-floor-choice-quiet")
            Button("Notify") { choose(setting, tier: "notify") }
                .accessibilityIdentifier("permission-floor-choice-notify")
            Button("Approve") { choose(setting, tier: "approve") }
                .accessibilityIdentifier("permission-floor-choice-approve")
            if layerLabel != "Built-in" {
                Button("Use built-in") { choose(setting, tier: nil) }
                    .accessibilityIdentifier("permission-floor-choice-builtin")
            }
        }
        .disabled(changingID == setting.id)
        .accessibilityIdentifier("permission-floor-\(setting.id)")
    }

    private func reload() {
        loadError = nil
        reloadTick &+= 1
    }

    private func load() async {
        let foreground = model.foregroundReconciliationGeneration
        let identity = model.knowledgePresentationIdentity
        let activity = presentationActivity
        guard activity.allowsPresentationPublication, !Task.isCancelled else { return }
        loadGeneration &+= 1
        let ticket = loadGeneration
        do {
            let resolution = try await model.resolveMacSettings(keys: [Self.key])
            guard ticket == loadGeneration, !Task.isCancelled,
                  identity == model.knowledgePresentationIdentity,
                  foreground == model.foregroundReconciliationGeneration,
                  activity == presentationActivity, activity.allowsPresentationPublication else { return }
            floors = resolution.keys
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard ticket == loadGeneration, !Task.isCancelled,
                  identity == model.knowledgePresentationIdentity,
                  foreground == model.foregroundReconciliationGeneration,
                  activity == presentationActivity, activity.allowsPresentationPublication else { return }
            // A failed read is shown as the screen's state with Reload, not as a transient notice.
            floors = nil
            loadError = error.localizedDescription
        }
    }

    /// The user's tap is the approval. Preview first: only a lowering (approve tier
    /// with Gateway confirm text) asks once more, in the dialog above.
    private func choose(_ setting: ResolvedSetting, tier: String?) {
        guard changingID == nil, presentationActivity.allowsPresentationPublication else { return }
        let change = Self.change(for: setting, tier: tier)
        let identity = model.knowledgePresentationIdentity
        changingID = setting.id
        Task { @MainActor in
            let preview: SettingsChangePreview
            do {
                preview = try await model.previewMacSettingsChange(change)
            } catch is CancellationError {
                changingID = nil
                return
            } catch {
                changingID = nil
                model.presentError(error)
                return
            }
            changingID = nil
            guard identity == model.knowledgePresentationIdentity else { return }
            if preview.tier == "approve", let confirm = preview.confirm {
                pendingLowering = PendingLowering(change: change, rowID: setting.id, message: confirm)
            } else {
                commit(change, rowID: setting.id)
            }
        }
    }

    /// Mutations are unstructured and never cancelled by the view; the reload
    /// that follows is a disposable read keyed on `reloadTick`.
    private func commit(_ change: JSONValue, rowID: String) {
        changingID = rowID
        let identity = model.knowledgePresentationIdentity
        Task { @MainActor in
            defer { changingID = nil }
            do {
                try await model.changeMacSetting(change)
                reloadTick &+= 1
            } catch is CancellationError {
                return
            } catch {
                guard identity == model.knowledgePresentationIdentity else { return }
                model.presentError(error)
            }
        }
    }

    private static func change(for setting: ResolvedSetting, tier: String?) -> JSONValue {
        let expected: JSONValue = setting.layer == "mac" ? (setting.value ?? .null) : .null
        var object: [String: JSONValue] = [
            "key": .string(key),
            "layer": .string("mac"),
            "op": .string(tier == nil ? "unset" : "set"),
            "qualifiers": .object((setting.qualifiers ?? [:]).mapValues { JSONValue.string($0) }),
            "expected": expected,
        ]
        if let tier { object["value"] = .string(tier) }
        return .object(object)
    }
}

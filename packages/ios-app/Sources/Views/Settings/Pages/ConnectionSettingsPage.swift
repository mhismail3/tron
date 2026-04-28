import SwiftUI

struct ConnectionSettingsPage: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let settingsState: SettingsState
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void
    let onAllPresetsRemoved: () -> Void

    @Environment(\.dependencies) private var dependencies
    @FocusState private var focusedField: Field?
    @State private var sheetMode: AddOrEditServerSheet.Mode?
    @State private var presetPendingRemoval: ConnectionPreset?
    @State private var removingPresetID: String?
    @State private var removalError: String?

    private enum Field {
        case host, port
    }

    var body: some View {
        SettingsPageContainer(title: "Server") {
            // Presets
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Presets")

                VStack(spacing: 8) {
                    ForEach(settingsState.connectionPresets) { preset in
                        presetRow(preset)
                    }

                    addPresetRow

                    if let removalError {
                        Text(removalError)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Server
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Server")

                SettingsCard {
                    HStack {
                        Image(systemName: "globe")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text("Host")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        Spacer()
                        TextField("localhost", text: $serverHost)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .multilineTextAlignment(.trailing)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .host)
                            .onSubmit { onHostSubmit() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .host }

                    SettingsRowDivider()

                    HStack {
                        Image(systemName: "number")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text("Port")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        Spacer()
                        TextField("9847", text: $serverPort)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                            .frame(width: 100)
                            .onChange(of: serverPort) { _, newValue in
                                if !newValue.isEmpty {
                                    onPortChange(newValue)
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .port }
                }
            }

            // Authentication (server.auth.enforced)
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Authentication")

                SettingsCard {
                    HStack {
                        Image(systemName: "lock.shield")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Require bearer token")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Text("Reject /ws upgrades without a matching Authorization header.")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextSecondary)
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { settingsState.authEnforced },
                                set: { newValue in
                                    settingsState.authEnforced = newValue
                                    updateServerSetting {
                                        var update = ServerSettingsUpdate()
                                        update.server = ServerSettingsUpdate.ServerUpdate(
                                            auth: ServerSettingsUpdate.ServerUpdate.AuthUpdate(enforced: newValue)
                                        )
                                        return update
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .tint(.tronEmerald)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }

                SettingsCaption(text: "Tokens live in `~/.tron/system/auth.json` on your Mac. Rotate from the menu bar or with `tron auth rotate`.")
            }

            // Tailscale identity (read-only display when populated)
            if let ip = settingsState.tailscaleIp, !ip.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader(title: "Tailscale")

                    SettingsCard {
                        HStack {
                            Image(systemName: "network")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text("Tailscale IP")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            Text(ip)
                                .font(TronTypography.code(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextSecondary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                    }

                    SettingsCaption(text: "Reported by your Mac. iOS uses this to display the recommended host on the pairing screen.")
                }
            }
        }
        // Add-or-edit server sheet — single sheet drives both flows.
        .sheet(item: $sheetMode) { mode in
            AddOrEditServerSheet(
                mode: mode,
                existingPresets: settingsState.connectionPresets,
                onCommit: { updatedPresets, activePreset in
                    handleSheetCommit(presets: updatedPresets, active: activePreset)
                }
            )
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .alert("Forget this Mac?", isPresented: removalAlertBinding, presenting: presetPendingRemoval) { preset in
            Button("Forget", role: .destructive) { handleRemove(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("Removes \(preset.label) from this iPhone and from the Mac's saved connection list. If no saved Macs remain, onboarding opens again.")
        }
        // Listen for re-pair-this-server requests from the chat-side
        // ConnectionStatusPill (`.unauthorized` tap). The notification
        // carries the active host:port pair; we resolve it to the matching
        // preset and open the sheet in edit mode. If no preset matches,
        // we open add-mode pre-filled with the current host/port.
        .onReceive(NotificationCenter.default.publisher(for: .rePairCurrentServer)) { _ in
            openRePairForActiveServer()
        }
    }

    // MARK: - Preset Row

    private func presetRow(_ preset: ConnectionPreset) -> some View {
        let selected = serverHost == preset.host && serverPort == String(preset.port)

        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeXL))
                .foregroundStyle(selected ? .tronEmerald : .tronTextMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Text("\(preset.host):\(String(preset.port))")
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }

            Spacer()

            if removingPresetID == preset.id {
                ProgressView()
                    .controlSize(.small)
                    .tint(.tronEmerald)
            } else {
                Menu {
                    Button {
                        sheetMode = .edit(preset)
                    } label: {
                        Label("Re-pair", systemImage: "key.fill")
                    }
                    Button(role: .destructive) {
                        presetPendingRemoval = preset
                    } label: {
                        Label("Forget this Mac", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextSecondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Manage \(preset.label)")
                .accessibilityIdentifier("preset.\(preset.id).menu")
            }
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                applyPreset(preset)
            }
        }
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var addPresetRow: some View {
        Button {
            sheetMode = .add
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeXL))
                    .foregroundStyle(.tronEmerald)

                Text("Add server")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("preset.add")
    }

    // MARK: - Actions

    private func applyPreset(_ preset: ConnectionPreset) {
        serverHost = preset.host
        let portString = String(preset.port)
        serverPort = portString
        onPortChange(portString)
        onHostSubmit()
    }

    /// Pop the re-pair sheet for the preset whose host:port match the
    /// active server. Falls back to add-mode (pre-filled with current
    /// host/port) when no matching preset exists yet.
    private func openRePairForActiveServer() {
        if let active = settingsState.connectionPresets.first(where: {
            $0.host == serverHost && String($0.port) == serverPort
        }) {
            sheetMode = .edit(active)
        } else {
            sheetMode = .add
        }
    }

    /// Commit handler for the sheet. Persists the updated preset list to
    /// the server, switches the active host/port to the just-saved preset,
    /// and triggers a manual reconnect so the new bearer token is exercised.
    private func handleSheetCommit(presets: [ConnectionPreset], active: ConnectionPreset) {
        // 1. Update the cached SettingsState immediately so the UI doesn't
        //    flicker waiting for the server round-trip.
        settingsState.replaceConnectionPresets(presets)

        // 2. Persist to the server.
        updateServerSetting {
            var update = ServerSettingsUpdate()
            update.server = ServerSettingsUpdate.ServerUpdate(connectionPresets: presets)
            return update
        }

        // 3. Switch active host/port to the just-saved preset.
        let portString = String(active.port)
        if serverHost != active.host || serverPort != portString {
            serverHost = active.host
            serverPort = portString
            onPortChange(portString)
            onHostSubmit()
        } else {
            // Same preset, just refreshed token — kick a manual retry so
            // the WS reconnect picks up the new token from Keychain.
            Task { await dependencies.connectionManager.manualRetry() }
        }
    }

    private func handleRemove(_ preset: ConnectionPreset) {
        guard removingPresetID == nil else { return }

        let plan = ConnectionPresetRemoval.plan(
            removing: preset,
            from: settingsState.connectionPresets,
            activeHost: serverHost,
            activePort: serverPort
        )

        var update = ServerSettingsUpdate()
        update.server = ServerSettingsUpdate.ServerUpdate(connectionPresets: plan.updatedPresets)

        removingPresetID = preset.id
        removalError = nil
        let client = dependencies.rpcClient
        Task {
            do {
                try await client.settings.update(update)
                await MainActor.run {
                    finishRemove(preset: preset, plan: plan)
                }
            } catch {
                await MainActor.run {
                    removingPresetID = nil
                    presetPendingRemoval = nil
                    removalError = "Could not forget \(preset.label): \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func finishRemove(preset: ConnectionPreset, plan: ConnectionPresetRemoval.Plan) {
        settingsState.replaceConnectionPresets(plan.updatedPresets)

        // Drop the bearer token from Keychain. Best-effort — failures here
        // would leave a dangling Keychain entry but don't affect correctness.
        try? dependencies.presetTokenStore.remove(presetId: preset.id)
        unregisterPushTokenFromCurrentServerIfNeeded(plan.removedWasActive)

        removingPresetID = nil
        presetPendingRemoval = nil

        if let next = plan.nextActivePreset {
            applyPreset(next)
        } else if plan.shouldReturnToOnboarding {
            onAllPresetsRemoved()
        }
    }

    private func unregisterPushTokenFromCurrentServerIfNeeded(_ shouldUnregister: Bool) {
        guard shouldUnregister,
              let deviceToken = dependencies.pushNotificationService.deviceToken else {
            return
        }

        let client = dependencies.rpcClient
        Task {
            try? await client.misc.unregisterDeviceToken(deviceToken)
        }
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(
            get: { presetPendingRemoval != nil },
            set: { if !$0 { presetPendingRemoval = nil } }
        )
    }
}

// MARK: - Sheet mode Identifiable

extension AddOrEditServerSheet.Mode: Identifiable {
    public var id: String {
        switch self {
        case .add: return "add"
        case .edit(let preset): return "edit:\(preset.id)"
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when the user taps the `.unauthorized` ConnectionStatusPill.
    /// The active settings sheet (if open) reacts by opening the re-pair
    /// sheet for the active server. If no settings sheet is open, the chat
    /// view first posts `.showSettingsAction` to bring it up.
    static let rePairCurrentServer = Notification.Name("rePairCurrentServer")
}

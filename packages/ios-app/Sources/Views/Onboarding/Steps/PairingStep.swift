import SwiftUI

/// Step 4 of the wizard — the heart of onboarding.
///
/// User enters (host, port, token, label). On Connect:
///   1. `PairingStepValidator.validate(...)` trims + classifies bad input.
///   2. `dependencies.pairingProbe.probe(...)` opens a one-shot WS upgrade
///      with `Authorization: Bearer <token>` and sends `system.ping`.
///      Result is classified into one of:
///        - `.ok` — proceed to commit
///        - `.unauthorized` — show `.unauthorized` failure
///        - `.incompatible` — show `.incompatibleServer(version)` failure
///        - `.unreachable` — show `.unreachable(host)` failure
///   3. On `.ok`, `PairingPersistor.plan(...)` produces the side-effect
///      plan, and the View applies it:
///        - Write token to `PresetTokenStore` keyed on the new preset id.
///        - Write `serverHost` / `serverPort` UserDefaults.
///        - Push the `connectionPresets[]` update to the server (via
///          `settings.set`) so the new preset survives reinstalls.
///        - Recreate the RPC client via
///          `dependencies.updateServerSettings(host:port:)`.
///   4. Advance to the Provider step.
///
/// **Universal-paste**: any `tron://pair?…` URL pasted into ANY of the
/// three text fields auto-distributes via `OnboardingState.acceptPairingPayload`.
/// Implemented through the shared `pasteAware()` helper extracted in
/// Phase 4.5.
struct PairingStep: View {
    @Bindable var state: OnboardingState
    let dependencies: DependencyContainer

    var body: some View {
        OnboardingShell(
            title: "Pair with your Mac",
            subtitle: "Open Tron.app on your Mac. Copy the host, port, and token from the pairing screen — or paste the full pairing link into any field.",
            onBack: { state.goBack() },
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    pairingForm
                    if let error = state.pairingError {
                        errorCard(error)
                    }
                }
            },
            footer: {
                OnboardingPrimaryButton(
                    title: state.isConnecting ? "Connecting…" : "Connect",
                    systemImage: state.isConnecting ? nil : "link",
                    isLoading: state.isConnecting,
                    isEnabled: !state.isConnecting,
                    action: connect
                )
            }
        )
    }

    // MARK: - Form

    @ViewBuilder
    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            field(
                label: "Tailscale IP or hostname",
                placeholder: "100.64.0.1 or mac-name.tail-scale.ts.net",
                text: $state.pairingHost,
                keyboard: .URL,
                contentType: .URL
            )
            field(
                label: "Port",
                placeholder: AppConstants.prodPort,
                text: $state.pairingPort,
                keyboard: .numberPad,
                contentType: nil
            )
            field(
                label: "Pairing token",
                placeholder: "Paste from Tron menu bar",
                text: $state.pairingToken,
                keyboard: .asciiCapable,
                contentType: nil,
                isSecure: true
            )
            field(
                label: "Label this server",
                placeholder: "My Mac",
                text: $state.pairingLabel,
                keyboard: .default,
                contentType: nil
            )
        }
    }

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        contentType: UITextContentType?,
        isSecure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .textCase(.uppercase)
            Group {
                let pasteAware = text.pasteAware { payload in
                    state.acceptPairingPayload(payload)
                }
                if isSecure {
                    SecureField(placeholder, text: pasteAware)
                } else {
                    TextField(placeholder, text: pasteAware)
                }
            }
            .font(TronTypography.code(size: TronTypography.sizeBody))
            .foregroundStyle(Color.tronTextPrimary)
            .keyboardType(keyboard)
            .textContentType(contentType)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .padding(.vertical, TronSpacing.xl)
            .padding(.horizontal, TronSpacing.section)
            .background(
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .fill(Color.tronSurfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .stroke(Color.tronBorder, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func errorCard(_ failure: PairingStepValidator.Failure) -> some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.tronError)
            Text(failure.userFacingMessage)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                .fill(Color.tronError.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                .stroke(Color.tronError.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Connect action

    private func connect() {
        state.pairingError = nil
        state.isConnecting = true

        switch PairingStepValidator.validate(
            host: state.pairingHost,
            port: state.pairingPort,
            token: state.pairingToken,
            label: state.pairingLabel
        ) {
        case .failure(let failure):
            state.pairingError = failure
            state.isConnecting = false
            return
        case .success(let payload):
            Task { await runProbe(payload: payload) }
        }
    }

    private func runProbe(payload: PairingURLParser.PairingPayload) async {
        let outcome = await dependencies.pairingProbe.probe(
            host: payload.host,
            port: payload.port,
            token: payload.token
        )
        if let probeError = outcome.toConnectError() {
            state.pairingError = PairingStepValidator.classify(
                error: probeError,
                hostHint: payload.host
            )
            state.isConnecting = false
            return
        }
        await commit(payload: payload)
    }

    private func commit(payload: PairingURLParser.PairingPayload) async {
        // Plan the side effects — pure, no I/O yet.
        let existing = readCachedPresets()
        let plan = PairingPersistor.plan(payload: payload, existing: existing)

        // 1. Keychain: write the bearer keyed on the (possibly-new) preset id.
        do {
            try dependencies.presetTokenStore.setToken(plan.token, forPresetId: plan.activePreset.id)
        } catch {
            state.pairingError = .unauthorized
            state.isConnecting = false
            return
        }

        // 2. Cache the updated preset list locally so the bearer-resolver
        //    closure (called on the next WS upgrade) can find the active
        //    preset even before the server settings.set round-trip completes.
        cachePresets(plan.updatedPresets)

        // 3. Switch the active server. updateServerSettings() rebuilds the
        //    RPC client with the new URL + bearer-token resolver in one go.
        dependencies.updateServerSettings(host: plan.activeHost, port: plan.activePort)

        // 4. Push the preset list to the server so it survives reinstalls.
        //    Best-effort — the local cache already covers this session.
        Task { try? await pushPresetList(plan.updatedPresets) }

        // 5. Mark connecting=false and walk forward.
        state.isConnecting = false
        state.advance()
    }

    // MARK: - Cached preset helpers

    private func readCachedPresets() -> [ConnectionPreset] {
        guard
            let data = UserDefaults.standard.data(forKey: SettingsState.cachedPresetsKey),
            let presets = try? JSONDecoder().decode([ConnectionPreset].self, from: data)
        else {
            return []
        }
        return presets
    }

    private func cachePresets(_ presets: [ConnectionPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: SettingsState.cachedPresetsKey)
        }
    }

    private func pushPresetList(_ presets: [ConnectionPreset]) async throws {
        // `connectionPresets` lives under the nested `server` block on
        // `ServerSettingsUpdate` — settings deep-merge replaces arrays
        // wholesale so we send the full post-edit list.
        let update = ServerSettingsUpdate(
            server: ServerSettingsUpdate.ServerUpdate(connectionPresets: presets)
        )
        try await dependencies.rpcClient.settings.update(update)
    }
}

// Universal-paste detection lives in `Extensions/Binding+PasteAware.swift`
// so the same code paths the Settings re-pair sheet uses are exercised by
// the onboarding form (Phase 4.5).

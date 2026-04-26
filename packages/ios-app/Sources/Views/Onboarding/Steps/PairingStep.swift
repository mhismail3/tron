import SwiftUI

/// Final onboarding page: scan, paste, or manually enter the Mac pairing
/// details, verify the server with `system.ping`, then persist the active
/// connection preset.
@available(iOS 26.0, *)
struct PairingStep: View {
    @Bindable var state: OnboardingState
    let dependencies: DependencyContainer
    let onPaired: () -> Void

    @State private var showQRScanner = false
    @State private var scanError: String?

    var body: some View {
        OnboardingPage(
            systemImage: "qrcode",
            title: "Connect your Mac",
            subtitle: "Scan the QR code from the Mac pairing screen, or enter the details manually."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                scanCard
                pairingForm

                if let scanError {
                    errorCard(scanError)
                }
                if let error = state.pairingError {
                    errorCard(error.userFacingMessage)
                }

                OnboardingPrimaryButton(
                    title: state.isConnecting ? "Connecting..." : "Connect",
                    systemImage: state.isConnecting ? nil : "link",
                    isLoading: state.isConnecting,
                    isEnabled: !state.isConnecting,
                    action: connect
                )
                .padding(.top, TronSpacing.sm)
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerSheet { code in
                applyScannedCode(code)
            }
        }
    }

    // MARK: - Content

    private var scanCard: some View {
        OnboardingGlassCard {
            HStack(alignment: .center, spacing: TronSpacing.section) {
                Image(systemName: "checkmark.shield.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Use the Mac pairing screen")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Text("Make sure Tailscale is on for both devices and Tron Server is running.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                OnboardingIconButton(
                    systemImage: "qrcode.viewfinder",
                    accessibilityLabel: "Scan pairing QR code",
                    action: { showQRScanner = true }
                )
            }
        }
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
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
                placeholder: "Paste from Tron on your Mac",
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

    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        contentType: UITextContentType?,
        isSecure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .textCase(.uppercase)

            Group {
                let pasteAware = text.pasteAware { payload in
                    scanError = nil
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
            .padding(.vertical, TronSpacing.md)
            .padding(.horizontal, TronSpacing.section)
            .glassEffect(
                .regular.tint(Color.tronOverlay(0.18)),
                in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
            )
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronError)
                .frame(width: 24)

            Text(message)
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

    // MARK: - QR

    private func applyScannedCode(_ code: String) {
        switch PairingURLParser.parse(code) {
        case .success(let payload):
            scanError = nil
            state.acceptPairingPayload(payload)
        case .failure:
            scanError = "That QR code does not look like a Tron pairing code."
        }
    }

    // MARK: - Connect action

    private func connect() {
        state.pairingError = nil
        scanError = nil
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
        let existing = readCachedPresets()
        let plan = PairingPersistor.plan(payload: payload, existing: existing)

        do {
            try dependencies.presetTokenStore.setToken(plan.token, forPresetId: plan.activePreset.id)
        } catch {
            state.pairingError = .keychainFailed(error.localizedDescription)
            state.isConnecting = false
            return
        }

        cachePresets(plan.updatedPresets)
        dependencies.updateServerSettings(host: plan.activeHost, port: plan.activePort)
        Task { try? await pushPresetList(plan.updatedPresets) }

        state.isConnecting = false
        dependencies.telemetryClient.track(.pairingCompleted)
        state.complete()
        onPaired()
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
        let update = ServerSettingsUpdate(
            server: ServerSettingsUpdate.ServerUpdate(connectionPresets: presets)
        )
        try await dependencies.rpcClient.settings.update(update)
    }
}

// Universal-paste detection lives in `Extensions/Binding+PasteAware.swift`
// so the same code paths the Settings re-pair sheet uses are exercised by
// the onboarding form.

import SwiftUI

/// Final onboarding page: scan, paste, or manually enter the Mac pairing
/// details, verify the server with `system::ping`, then persist the active
/// paired server locally on this device.
@available(iOS 26.0, *)
struct PairingStep: View {
    @Bindable var state: OnboardingState
    let dependencies: DependencyContainer
    let onPaired: () -> Void

    @State private var showQRScanner = false
    @State private var scanError: String?
    @State private var pendingScannedPayload: PairingURLParser.PairingPayload?
    @State private var showsManualEntry = false

    var body: some View {
        OnboardingPage(
            subtitle: "Use the pairing screen shown by the Mac installer."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                qrPairingCard
                manualEntryToggle

                if showsManualEntry {
                    manualEntrySection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let scanError {
                    errorCard(scanError)
                }
                if let error = state.pairingError {
                    errorCard(error.userFacingMessage)
                }
            }
        }
        .animation(.snappy(duration: 0.24), value: showsManualEntry)
        .sheet(isPresented: $showQRScanner, onDismiss: connectAfterSuccessfulScan) {
            QRCodeScannerSheet { code in
                applyScannedCode(code)
            }
        }
        .toolbar {
            if state.currentStep == .connect {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: connect) {
                        if state.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Connect")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        }
                    }
                    .disabled(!state.canAttemptPairing)
                    .opacity(state.canAttemptPairing ? 1 : 0.45)
                    .accessibilityLabel(state.isConnecting ? "Connecting" : "Connect to Mac")
                }
            }
        }
    }

    // MARK: - Content

    private var qrPairingCard: some View {
        OnboardingGlassCard {
            HStack(alignment: .center, spacing: TronSpacing.section) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan the Mac QR code")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Text("This fills in the host, port, token, and server name automatically.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: openScanner) {
                    Image(systemName: "camera.viewfinder")
                        .font(TronTypography.sans(size: TronTypography.sizeHero, weight: .semibold))
                        .frame(width: 76, height: 76)
                        .foregroundStyle(Color.tronEmerald)
                        .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(0.18)).interactive(),
                    in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                )
                .accessibilityLabel("Scan QR code")
            }
        }
    }

    private var manualEntryToggle: some View {
        Button {
            scanError = nil
            withAnimation(.snappy(duration: 0.24)) {
                showsManualEntry.toggle()
            }
        } label: {
            Text(showsManualEntry ? "Hide Manual Entry" : "Enter Manually")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .padding(.top, TronSpacing.sm)
    }

    private var manualEntrySection: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Text("Manual entry")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)

            Text("Paste the pairing link or type the values from the Mac app.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            pairingForm
                .padding(.top, 4)
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
                label: "Server Name",
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

    private func openScanner() {
        pendingScannedPayload = nil
        scanError = nil
        state.pairingError = nil
        showQRScanner = true
    }

    private func applyScannedCode(_ code: String) {
        switch PairingURLParser.parse(code) {
        case .success(let payload):
            scanError = nil
            pendingScannedPayload = payload
            showsManualEntry = false
            state.acceptPairingPayload(payload)
        case .failure:
            pendingScannedPayload = nil
            scanError = "That QR code does not look like a Tron pairing code."
        }
    }

    private func connectAfterSuccessfulScan() {
        guard let payload = pendingScannedPayload else { return }
        pendingScannedPayload = nil
        runValidatedConnect(payload)
    }

    // MARK: - Connect action

    private func connect() {
        scanError = nil
        state.pairingError = nil

        guard let payload = state.validatedPairingPayload(storedToken: storedPrefilledToken) else {
            state.pairingError = pairingValidationFailure
            return
        }

        runValidatedConnect(payload)
    }

    private func runValidatedConnect(_ payload: PairingURLParser.PairingPayload) {
        state.beginPairingEntry()
        scanError = nil
        state.isConnecting = true
        Task { await runProbe(payload: payload) }
    }

    private var storedPrefilledToken: String? {
        guard let serverId = state.pairingPrefilledServerId,
              state.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return dependencies.pairedServerTokenStore.token(forServerId: serverId)
    }

    private var pairingValidationFailure: PairingStepValidator.Failure {
        if state.pairingPrefilledServerId != nil,
           state.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           storedPrefilledToken == nil,
           state.pairingValidationFailure(storedToken: "stored-token") == nil {
            return .storedTokenMissing
        }
        return state.pairingValidationFailure() ?? .missingFields
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
        let existing = dependencies.pairedServerStore.servers
        let previousActiveId = dependencies.pairedServerStore.activeServerId
        let plan = PairingPersistor.plan(payload: payload, existing: existing)
        let previousToken = dependencies.pairedServerTokenStore.token(forServerId: plan.activeServer.id)

        do {
            try dependencies.pairedServerTokenStore.setToken(plan.token, forServerId: plan.activeServer.id)
        } catch {
            state.pairingError = .keychainFailed(error.localizedDescription)
            state.isConnecting = false
            return
        }

        dependencies.replacePairedServers(plan.updatedServers, activeServer: plan.activeServer)
        let client = dependencies.engineClient

        do {
            await client.connect()
            let settings = try await client.settings.get()
            guard dependencies.pairedServerStore.activeServer?.id == plan.activeServer.id,
                  dependencies.engineClient === client
            else {
                state.pairingError = .settingsFailed("Active server changed before setup settings loaded.")
                state.isConnecting = false
                return
            }
            dependencies.applyServerSettingsSnapshot(settings, for: plan.activeServer.id)

            do {
                let authState = try await client.auth.get()
                state.hydrateSetup(serverId: plan.activeServer.id, settings: settings, authState: authState)
            } catch {
                state.hydrateSetup(
                    serverId: plan.activeServer.id,
                    settings: settings,
                    authState: nil,
                    authLoadError: error.localizedDescription
                )
            }
        } catch {
            rollbackPairingState(
                to: existing,
                previousActiveId: previousActiveId,
                pairedServerId: plan.activeServer.id,
                previousToken: previousToken
            )
            state.pairingError = .settingsFailed(error.localizedDescription)
            state.isConnecting = false
            return
        }

        state.isConnecting = false
        onPaired()
    }

    private func rollbackPairingState(
        to servers: [PairedServer],
        previousActiveId: String?,
        pairedServerId: String,
        previousToken: String?
    ) {
        dependencies.replacePairedServers(servers, activeId: previousActiveId)
        if let previousToken {
            try? dependencies.pairedServerTokenStore.setToken(previousToken, forServerId: pairedServerId)
        } else {
            try? dependencies.pairedServerTokenStore.remove(serverId: pairedServerId)
        }
    }
}

// Universal-paste detection lives in `Extensions/Binding+PasteAware.swift`
// so pairing URLs pasted into any onboarding field are distributed cleanly.

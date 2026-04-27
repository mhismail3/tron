import SwiftUI

/// Modal sheet for adding a brand-new connection preset OR re-pairing
/// an existing one (refreshing its bearer token).
///
/// **Design choice — single sheet, two modes.** Add and re-pair share
/// 90% of their UI (server name + host + port + token + "Connect" button).
/// The mode parameter discriminates the small differences:
/// - **add** — generates a fresh preset id; appends to `connectionPresets`.
/// - **edit(preset)** — locks the host/port/label fields (preset identity is
///   stable; if you really want to change them, remove and re-add); only
///   the token field is editable; persists the new token to Keychain
///   without touching the server-side preset list.
///
/// **Validation** is currently store-and-reconnect: we save the token and
/// trigger `manualRetry`. The user sees the existing `ConnectionStatusPill`
/// transition through `.connecting` → `.connected` (success) or back to
/// `.unauthorized` (wrong token). Phase 4's onboarding Pairing step will
/// add a synchronous `system.ping` validation path because it has no
/// fallback — for re-pair we DO have a fallback (the user just opens this
/// sheet again).
///
/// **Universal paste detection** — pasting a `tron://pair?…` URL into any
/// text field auto-distributes to all three fields via `PairingURLParser`.
struct AddOrEditServerSheet: View {

    enum Mode: Equatable {
        case add
        case edit(ConnectionPreset)

        var isEdit: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    let mode: Mode
    let existingPresets: [ConnectionPreset]
    /// Called with the updated `[ConnectionPreset]` (full list) after the
    /// user commits. Caller is responsible for posting it to the server
    /// via `updateServerSetting` and refreshing `SettingsState` if needed.
    let onCommit: (_ updatedPresets: [ConnectionPreset], _ activePreset: ConnectionPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies

    @State private var label: String = ""
    @State private var host: String = ""
    @State private var port: String = AppConstants.prodPort
    @State private var token: String = ""
    @State private var inlineError: String?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case label, host, port, token }

    var body: some View {
        SettingsPageContainer(title: mode.isEdit ? "Re-pair server" : "Add server") {
            // Quick-paste hint
            if !mode.isEdit {
                SettingsCaption(text: "Paste a `tron://pair?…` link into any field to auto-fill from the Mac wizard's QR code or pairing screen.")
            }

            // Form
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Server")

                SettingsCard {
                    formRow(icon: "tag", title: "Label", placeholder: "My Mac", binding: $label, field: .label, locked: mode.isEdit)
                    SettingsRowDivider()
                    formRow(icon: "globe", title: "Host", placeholder: "100.64.0.1", binding: $host, field: .host, locked: mode.isEdit)
                    SettingsRowDivider()
                    formRow(icon: "number", title: "Port", placeholder: AppConstants.prodPort, binding: $port, field: .port, locked: mode.isEdit, keyboard: .numberPad)
                    SettingsRowDivider()
                    formRow(
                        icon: "key.fill",
                        title: "Token",
                        placeholder: "Bearer token from Mac menu bar",
                        binding: $token,
                        field: .token,
                        locked: false,
                        secure: true
                    )
                }
            }

            if let error = inlineError {
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("addOrEditServerSheet.error")
            }

            // Actions
            VStack(spacing: 8) {
                Button(action: commit) {
                    Text(mode.isEdit ? "Save & reconnect" : "Add server")
                        .font(TronTypography.button)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(canCommit ? Color.tronEmerald : Color.tronTextMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(!canCommit)
                .accessibilityIdentifier("addOrEditServerSheet.commit")

                Button("Cancel") { dismiss() }
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        .onAppear { primeForMode() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func formRow(
        icon: String,
        title: String,
        placeholder: String,
        binding: Binding<String>,
        field: Field,
        locked: Bool,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            Spacer()
            Group {
                let pasteAwareBinding = binding.pasteAware { payload in
                    if mode.isEdit {
                        // Re-pair: identity fields are locked. Only refresh
                        // the token. Pasting a URL from a *different* server
                        // would otherwise silently mutate the locked
                        // host/port/label.
                        token = payload.token
                    } else {
                        let distributed = payload.distributing(currentLabel: label)
                        host = distributed.host
                        port = distributed.port
                        token = distributed.token
                        label = distributed.label
                    }
                    inlineError = nil
                }
                if secure {
                    SecureField(placeholder, text: pasteAwareBinding)
                } else {
                    TextField(placeholder, text: pasteAwareBinding)
                }
            }
            .font(TronTypography.sans(size: TronTypography.sizeBody))
            .multilineTextAlignment(.trailing)
            .keyboardType(keyboard)
            .autocapitalization(.none)
            .autocorrectionDisabled()
            .disabled(locked)
            .focused($focusedField, equals: field)
            .submitLabel(field == .token ? .go : .next)
            .onSubmit { advanceFocus(from: field) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .opacity(locked ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !locked { focusedField = field } }
    }

    // Paste detection lives in `Extensions/Binding+PasteAware.swift`
    // and field-distribution lives in
    // `PairingURLParser.PairingPayload.distributing(currentLabel:)` so the
    // onboarding `PairingStep` (via `OnboardingState.acceptPairingPayload`)
    // and this re-pair sheet share both the tron://pair-detection AND the
    // "what counts as user-edited" rule.

    private func advanceFocus(from field: Field) {
        switch field {
        case .label: focusedField = .host
        case .host: focusedField = .port
        case .port: focusedField = .token
        case .token: commit()
        }
    }

    // MARK: - State

    private var canCommit: Bool {
        let labelOk = !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hostOk = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tokenOk = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let portOk = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)).map { (1...65_535).contains($0) } ?? false
        return labelOk && hostOk && portOk && tokenOk
    }

    private func primeForMode() {
        if case .edit(let preset) = mode {
            label = preset.label
            host = preset.host
            port = String(preset.port)
            // Token intentionally NOT pre-populated. Keychain reads are
            // possible but we want the user to physically re-enter the
            // current token from the Mac menu bar — that's the whole point
            // of the re-pair flow. Surface a hint instead.
            token = ""
            focusedField = .token
        } else {
            focusedField = .label
        }
    }

    // MARK: - Commit

    private func commit() {
        let decision = AddOrEditServerSheetCommit.decide(
            mode: mode,
            existingPresets: existingPresets,
            rawLabel: label,
            rawHost: host,
            rawPort: port,
            rawToken: token,
            idGenerator: { UUID().uuidString }
        )
        switch decision {
        case .success(let outcome):
            // Persist the bearer token to Keychain BEFORE notifying the caller
            // so that the immediately-following reconnect picks up the new token.
            do {
                try dependencies.presetTokenStore.setToken(
                    outcome.trimmedToken,
                    forPresetId: outcome.activePreset.id
                )
            } catch {
                inlineError = "Could not save token to Keychain: \(error.localizedDescription)"
                return
            }
            onCommit(outcome.updatedPresets, outcome.activePreset)
            dismiss()
        case .failure(let failure):
            inlineError = failure.userFacingMessage
        }
    }
}

// MARK: - Pure-value commit logic

/// Pure-value wrapper for the validate-and-build-preset decision the sheet
/// performs on commit. Extracted from the View so unit tests can exercise
/// every classified failure branch without standing up SwiftUI environments,
/// dependencies, or Keychain access.
///
/// The View remains responsible for the side effects (Keychain write,
/// dismiss, callback) — this helper is a referentially-transparent function
/// over its inputs so tests can cover happy-path AND every failure surface
/// in microseconds.
enum AddOrEditServerSheetCommit {

    struct Outcome: Equatable {
        let updatedPresets: [ConnectionPreset]
        let activePreset: ConnectionPreset
        let trimmedToken: String
    }

    enum Failure: Error, Equatable {
        /// Any of label / host / port / token is empty or whitespace-only.
        case missingFields
        /// Port parses but is outside `1...65535`, OR doesn't parse at all.
        case invalidPort(String)
        /// `.add` mode rejected because `(host, port)` already exists.
        case duplicateHostPort(host: String, port: Int)

        var userFacingMessage: String {
            switch self {
            case .missingFields:
                return "Fill in label, host, port, and token before continuing."
            case .invalidPort:
                return "Port must be a number between 1 and 65535."
            case .duplicateHostPort(let host, let port):
                return "A preset for \(host):\(port) already exists. Use Re-pair on that row instead."
            }
        }
    }

    static func decide(
        mode: AddOrEditServerSheet.Mode,
        existingPresets: [ConnectionPreset],
        rawLabel: String,
        rawHost: String,
        rawPort: String,
        rawToken: String,
        idGenerator: () -> String = { UUID().uuidString }
    ) -> Result<Outcome, Failure> {
        let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPortRaw = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLabel.isEmpty, !trimmedHost.isEmpty, !trimmedToken.isEmpty, !trimmedPortRaw.isEmpty else {
            return .failure(.missingFields)
        }
        guard let portInt = Int(trimmedPortRaw), (1...65_535).contains(portInt) else {
            return .failure(.invalidPort(trimmedPortRaw))
        }

        let preset: ConnectionPreset
        var updated = existingPresets
        switch mode {
        case .add:
            if existingPresets.contains(where: { $0.host == trimmedHost && $0.port == portInt }) {
                return .failure(.duplicateHostPort(host: trimmedHost, port: portInt))
            }
            preset = ConnectionPreset(
                id: idGenerator(),
                label: trimmedLabel,
                host: trimmedHost,
                port: portInt
            )
            updated.append(preset)
        case .edit(let existing):
            // Edit mode locks identity fields — preserve the existing preset
            // wholesale so the Keychain key and server-side id stay stable.
            preset = existing
        }

        return .success(Outcome(
            updatedPresets: updated,
            activePreset: preset,
            trimmedToken: trimmedToken
        ))
    }
}

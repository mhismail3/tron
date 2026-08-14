import AppKit
import SwiftUI

struct PairingInfoStep: View {
    @Bindable var state: GatewayOnboardingModel
    @State private var qrImage: NSImage?
    @State private var copiedField: PairingCopyField?
    @State private var copyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install or open Tron on your iPhone, sign in to the same Tailscale network, then scan this code.")
                .font(TronTypography.wizardBodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 20) {
                qrPanel
                detailsPanel
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer()
                Button {
                    state.refreshPairing()
                } label: {
                    Label(state.pairingFailure == nil ? "Refresh" : "Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.wizardLink)
                .disabled(state.isRefreshing)
            }
            Spacer(minLength: 0)
        }
        .task { state.refreshPairing(initialDelay: true) }
        .onChange(of: state.pairingPayload) { _, payload in renderQRCode(payload) }
        .onDisappear {
            copyTask?.cancel()
            copyTask = nil
        }
    }

    private var qrPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(qrImage == nil ? Color.tronEmerald.opacity(0.05) : .white)
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .accessibilityLabel("Tron iPhone pairing code")
            } else if state.isRefreshing {
                ProgressView().controlSize(.large).accessibilityLabel("Refreshing pairing code")
            } else {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald.opacity(0.7))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 170, height: 170)
        .wizardGlassCard()
    }

    @ViewBuilder
    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payload = state.pairingPayload {
                valueRow(.tailscaleIP, "Tailscale IP", payload.host)
                valueRow(.port, "Port", String(payload.port))
                valueRow(.pairingCode, "Pairing code", payload.code, masked: true)
                valueRow(.macName, "Mac name", payload.label ?? LocalComputerName.defaultName)
            } else if let failure = state.pairingFailure {
                WizardInfoCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failureTitle(failure)).font(TronTypography.wizardSubheadline)
                        Text(failureDetail(failure))
                            .font(TronTypography.wizardCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: 218, alignment: .center)
    }

    private func valueRow(
        _ field: PairingCopyField,
        _ label: String,
        _ value: String,
        masked: Bool = false
    ) -> some View {
        WizardInfoCard(verticalPadding: 6, horizontalPadding: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                    Text(masked ? mask(value) : value)
                        .font(TronTypography.wizardCodeValue)
                        .lineLimit(1)
                        .truncationMode(masked ? .middle : .tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copy(value, field: field)
                } label: {
                    Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(Color.tronEmerald)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(label)")
            }
        }
    }

    private func renderQRCode(_ payload: PairingPayload?) {
        guard let payload,
              let url = PairingURLBuilder.makeURL(payload),
              let image = QRCodeGenerator.makeImage(payload: url.absoluteString, size: 170) else {
            qrImage = nil
            if payload != nil { state.pairingFailure = .qrGenerationFailed }
            return
        }
        qrImage = image
    }

    private func copy(_ value: String, field: PairingCopyField) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
        copyTask?.cancel()
        copyTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard copiedField == field else { return }
            copiedField = nil
        }
    }

    private func mask(_ value: String) -> String {
        value.count > 9 ? "\(value.prefix(4))…\(value.suffix(4))" : value
    }

    private func failureTitle(_ failure: PairingFailureReason) -> String {
        switch failure {
        case .noCode: "Pairing code unavailable"
        case .gatewayUnreachable: "Gateway unavailable"
        case .localAuthenticationFailed: "Authorization failed"
        case .noTailscaleIP: "Tailscale unavailable"
        case .qrGenerationFailed: "QR code unavailable"
        }
    }

    private func failureDetail(_ failure: PairingFailureReason) -> String {
        switch failure {
        case .noCode: "Wait a moment, then retry to request the current one-time code."
        case .gatewayUnreachable: "Restart Tron Gateway from the menu bar, then retry."
        case .localAuthenticationFailed: "Restart Tron Gateway to renew local authorization."
        case .noTailscaleIP: "Connect Tailscale on this Mac, then retry."
        case .qrGenerationFailed: "Retry, or use the manual values when they are available."
        }
    }
}

private enum PairingCopyField: Hashable {
    case tailscaleIP
    case port
    case pairingCode
    case macName
}

struct PairingInfoWindowView: View {
    @State private var state: GatewayOnboardingModel

    init(
        dependencies: GatewayDependencies,
        coordinator: GatewayLifecycleCoordinator
    ) {
        _state = State(initialValue: GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: coordinator,
            initialStep: .connectIPhone
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pairing Info")
                .font(TronTypography.wizardTitle)
                .foregroundStyle(Color.tronEmerald)
                .accessibilityAddTraits(.isHeader)
            PairingInfoStep(state: state)
        }
        .padding(.horizontal, WizardLayout.horizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: WizardLayout.width, height: 360)
        .onDisappear { state.cancelAll() }
    }
}

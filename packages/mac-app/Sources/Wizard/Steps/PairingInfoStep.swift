import SwiftUI
import AppKit

struct PairingInfoStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var qrImage: NSImage?
    @State private var qrPayloadString: String?
    @State private var failureReason: PairingFailureReason?

    /// Why we couldn't render a pairing payload. Drives the warning
    /// panel copy so the user knows whether to wait (server still
    /// starting) vs. fix Tailscale.
    enum PairingFailureReason {
        case noToken
        case noTailscaleIP
    }

    var body: some View {
        // Title is rendered by `WizardShell.headerRow` — body starts
        // with the description text directly.
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Tron on your iPhone and tap “I have Tron running”. Either scan the QR code below or enter the values manually.")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 24) {
                qrPanel
                infoPanel
            }

            HStack {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)

                Spacer()

                Button {
                    state.complete()
                } label: {
                    Text("I'm paired — finish setup")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(state.pairingPayload == nil)
            }
        }
        .task { refresh() }
    }

    @ViewBuilder
    private var qrPanel: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thickMaterial)
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 220, height: 220)

            if let qrPayloadString {
                Text(qrPayloadString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 220)
            }
        }
    }

    @ViewBuilder
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let payload = state.pairingPayload {
                pairingRow(label: "Tailscale IP", value: payload.host)
                pairingRow(label: "Port", value: String(payload.port))
                pairingRow(label: "Pairing token", value: payload.token, masked: true)
            } else {
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failureHeadline).font(.headline)
                            Text(failureBody)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func pairingRow(label: String, value: String, masked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(masked ? maskValue(value) : value)
                    .font(.body.monospaced())
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
            }
        }
        .padding(8)
        .background(.windowBackground.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func maskValue(_ value: String) -> String {
        guard value.count > 9 else { return value }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }

    private var failureHeadline: String {
        switch failureReason {
        case .noTailscaleIP: return "Tailscale IP not detected"
        case .noToken, .none: return "Server not yet reachable"
        }
    }

    private var failureBody: String {
        switch failureReason {
        case .noTailscaleIP:
            return "The server is running but we can't read this Mac's Tailscale IP. Open Tailscale and confirm you're signed in, then tap Refresh."
        case .noToken, .none:
            return "If you skipped the install step, make sure Tron is running. Otherwise wait a few seconds and tap Refresh."
        }
    }

    private func refresh() {
        Task {
            // Resolve the pairing payload by combining the on-disk
            // bearer token with the server's `system.getInfo` response.
            // We accept `.success` only; on `.unauthorized` the server
            // is up but our local token is stale (rotation without
            // restart), so we still surface the info from settings
            // rather than block the user.
            //
            // Both `host` and `token` must be real before we render
            // pairing info — a placeholder/fallback IP would mislead
            // the user into typing a non-routable address into iOS.
            let token = setup.readBearerToken()
            let info = await setup.pingServer(token).info
            let host = info?.tailscaleIp
                ?? setup.readTailscaleIPFromSettings()
            let port = info?.port ?? setup.serverPort

            guard let token, !token.isEmpty else {
                state.pairingPayload = nil
                qrPayloadString = nil
                qrImage = nil
                failureReason = .noToken
                return
            }
            guard let host, !host.isEmpty else {
                state.pairingPayload = nil
                qrPayloadString = nil
                qrImage = nil
                failureReason = .noTailscaleIP
                return
            }

            let payload = PairingPayload(host: host, port: port, token: token, label: "My Mac")
            state.pairingPayload = payload
            failureReason = nil
            if let url = PairingURLBuilder.makeURL(payload) {
                qrPayloadString = url.absoluteString
                qrImage = QRCodeGenerator.makeImage(payload: url.absoluteString, size: 220)
            }
        }
    }
}

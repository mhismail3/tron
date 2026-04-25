import SwiftUI
import AppKit

/// Pairing-info step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / "I'm paired", with the primary
/// gated by `state.pairingPayload != nil` in `WizardShell`). This view
/// contributes the description, the QR + info side-by-side panels,
/// and an inline Refresh icon-button that re-runs the pairing
/// resolver.
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

    /// QR code rendered side dimension. Picked to fit alongside the
    /// info panel inside the shell's content area at the current
    /// window height (360pt) once the header (~46pt), the
    /// description row (~36pt), and the bottom bar (~70pt) are
    /// subtracted. 170pt is the largest square that still leaves
    /// enough vertical room for the single-line URL caption beneath
    /// the QR.
    private let qrSize: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Open Tron on your iPhone, tap “I have Tron running”, then scan the QR or enter the values manually.")
                    .font(TronTypography.wizardBodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                // Tertiary action: lives inline (rather than in the
                // shell's bottom bar) so it slides with the rest of
                // the body content. Compact icon-button form keeps
                // the description row visually tidy.
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.tronEmerald.opacity(0.30), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Refresh pairing info")
            }

            HStack(alignment: .top, spacing: 20) {
                qrPanel
                infoPanel
            }

            Spacer(minLength: 0)
        }
        .task { refresh() }
    }

    @ViewBuilder
    private var qrPanel: some View {
        VStack(spacing: 6) {
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
            .frame(width: qrSize, height: qrSize)

            if let qrPayloadString {
                // Single-line caption — at the shorter window height,
                // a two-line wrap pushes the info panel off-screen.
                // Truncate the middle of the URL so both ends (the
                // host and the token tail) stay legible.
                Text(qrPayloadString)
                    .font(TronTypography.wizardCodeCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: qrSize)
            }
        }
    }

    @ViewBuilder
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payload = state.pairingPayload {
                pairingRow(label: "Tailscale IP", value: payload.host)
                pairingRow(label: "Port", value: String(payload.port))
                pairingRow(label: "Pairing token", value: payload.token, masked: true)
            } else {
                WizardInfoCard {
                    WizardIconTextRow(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failureHeadline).font(TronTypography.wizardSubheadline)
                            Text(failureBody)
                                .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pairingRow(label: String, value: String, masked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(TronTypography.wizardCaption).foregroundStyle(.secondary)
            HStack {
                Text(masked ? maskValue(value) : value)
                    .font(TronTypography.wizardCodeValue)
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
        .padding(6)
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
            return "The server is running but we can't read this Mac's Tailscale IP. Open Tailscale, confirm sign-in, then tap Refresh."
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
                qrImage = QRCodeGenerator.makeImage(payload: url.absoluteString, size: qrSize)
            }
        }
    }
}

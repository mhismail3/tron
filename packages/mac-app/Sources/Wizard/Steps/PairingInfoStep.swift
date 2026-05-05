import SwiftUI
import AppKit

/// Pairing-info step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / "I'm paired", with the primary
/// gated by `state.pairingPayload != nil` in `WizardShell`). This view
/// contributes the description, the QR + info side-by-side panels,
/// and copy controls for the resolved pairing values.
struct PairingInfoStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var failureReason: PairingFailureReason?
    @State private var isRefreshing = false
    @State private var copiedField: PairingCopyField?
    @State private var resolvedQRCode: NSImage?

    /// Why we couldn't render a pairing payload. Drives the warning
    /// panel copy so the user knows whether to wait (server still
    /// starting) vs. fix Tailscale.
    enum PairingFailureReason {
        case noToken
        case serverUnreachable
        case tokenRejected
        case noTailscaleIP
        case qrGenerationFailed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Tron on your iPhone. Make sure Tailscale is signed in there with the same account, then scan the QR or enter the values manually.")
                .font(TronTypography.wizardBodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            pairingCluster

            Spacer(minLength: 0)
        }
        .task { await refresh(delayForInitialTransition: true) }
    }

    @ViewBuilder
    private var pairingCluster: some View {
        ZStack {
            loadingPanel
                .opacity(shouldShowLoading ? 1 : 0)
                .scaleEffect(shouldShowLoading ? 1 : 0.985)
                .allowsHitTesting(false)

            if shouldShowResolvedPairing {
                HStack(alignment: .center, spacing: PairingInfoStepLayout.columnSpacing) {
                    qrPanel
                    infoPanel
                }
                .transition(PairingInfoStepLayout.revealTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(PairingInfoStepLayout.revealAnimation, value: shouldShowLoading)
        .animation(PairingInfoStepLayout.revealAnimation, value: shouldShowResolvedPairing)
        .animation(PairingInfoStepLayout.revealAnimation, value: failureReason != nil)
    }

    private var shouldShowLoading: Bool {
        state.pairingPayload == nil && failureReason == nil
    }

    private var shouldShowResolvedPairing: Bool {
        state.pairingPayload != nil || failureReason != nil
    }

    private var loadingPanel: some View {
        PairingResolvingSpinner()
            .frame(
                width: PairingInfoStepLayout.clusterWidth,
                height: PairingInfoStepLayout.clusterHeight
            )
    }

    @ViewBuilder
    private var qrPanel: some View {
        ZStack {
            if let qrImage = resolvedQRCode {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .overlay {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
                    .transition(PairingInfoStepLayout.revealTransition)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald.opacity(0.75))
                    Text("Pairing info unavailable")
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .transition(.opacity)
            }
        }
        .frame(width: PairingInfoStepLayout.qrSize, height: PairingInfoStepLayout.qrSize)
        .wizardGlassCard()
        .animation(PairingInfoStepLayout.revealAnimation, value: state.pairingPayload)
    }

    @ViewBuilder
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payload = state.pairingPayload {
                Group {
                    pairingRow(field: .tailscaleIP, label: "Tailscale IP", value: payload.host)
                    pairingRow(field: .port, label: "Port", value: String(payload.port))
                    pairingRow(field: .pairingToken, label: "Pairing token", value: payload.token, masked: true)
                    pairingRow(field: .serverName, label: "Server name", value: payload.label ?? LocalComputerName.fallback)
                }
                .transition(PairingInfoStepLayout.revealTransition)
            } else if let failureReason {
                failurePanel(for: failureReason)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: PairingInfoStepLayout.valueColumnWidth, alignment: .center)
        .animation(PairingInfoStepLayout.revealAnimation, value: state.pairingPayload)
    }

    private func failurePanel(for reason: PairingFailureReason) -> some View {
        WizardInfoCard {
            WizardIconTextRow(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(failureHeadline(for: reason)).font(TronTypography.wizardSubheadline)
                    Text(failureBody(for: reason))
                        .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func pairingRow(field: PairingCopyField, label: String, value: String, masked: Bool = false) -> some View {
        WizardInfoCard(
            verticalPadding: PairingInfoStepLayout.valueCardVerticalPadding,
            horizontalPadding: PairingInfoStepLayout.valueCardHorizontalPadding
        ) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                    Text(masked ? maskValue(value) : value)
                        .font(TronTypography.wizardCodeValue)
                        .lineLimit(1)
                        .truncationMode(masked ? .middle : .tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    copy(value, field: field)
                } label: {
                    Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .frame(width: 24, height: 24)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }

    private func maskValue(_ value: String) -> String {
        guard value.count > 9 else { return value }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }

    private func failureHeadline(for reason: PairingFailureReason) -> String {
        switch reason {
        case .noTailscaleIP: return "Tailscale IP not detected"
        case .noToken: return "Pairing token missing"
        case .serverUnreachable: return "Server not reachable"
        case .tokenRejected: return "Pairing token rejected"
        case .qrGenerationFailed: return "QR code failed"
        }
    }

    private func failureBody(for reason: PairingFailureReason) -> String {
        switch reason {
        case .noTailscaleIP:
            return "Open Tailscale on this Mac and confirm it is signed in. Fresh installs do not need a pre-existing user profile."
        case .noToken:
            return "The server has not written its local pairing token yet. Go back to Install or wait a few seconds, then reopen Pairing Info."
        case .serverUnreachable:
            return "Tron Server did not answer on this Mac. Go back to Install to confirm it is running, then reopen Pairing Info."
        case .tokenRejected:
            return "The local token file does not match the running server. Restart Tron Server from the menu bar, then reopen Pairing Info."
        case .qrGenerationFailed:
            return "The pairing values were resolved, but the QR code could not be generated. Use the manual values or reopen Pairing Info."
        }
    }

    @MainActor
    private func refresh(delayForInitialTransition: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        failureReason = nil
        defer { isRefreshing = false }

        if delayForInitialTransition, state.pairingPayload == nil {
            try? await Task.sleep(nanoseconds: PairingInfoStepLayout.initialResolveDelayNanoseconds)
            if Task.isCancelled { return }
        }

        // Fresh installs do not have a user profile yet. Resolve the
        // current Tailscale address live, then cache it into the profile
        // only after we know the value is real.
        let token = setup.readBearerToken()
        guard let token, !token.isEmpty else {
            fail(.noToken)
            return
        }

        let pingResult = await setup.pingServer(token)
        let info: ServerInfo
        switch pingResult {
        case .success(let serverInfo):
            info = serverInfo
        case .unauthorized:
            fail(.tokenRejected)
            return
        case .unreachable, .timeout, .malformedResponse:
            fail(.serverUnreachable)
            return
        }

        let liveTailscale = await setup.probeTailscale()
        if case .signedIn = liveTailscale {
            state.tailscaleStatus = liveTailscale
        }

        guard let host = firstNonEmpty(
            liveTailscale.displayIP,
            state.tailscaleStatus?.displayIP,
            info.tailscaleIp,
            setup.readTailscaleIPFromSettings()
        ) else {
            fail(.noTailscaleIP)
            return
        }

        setup.cacheTailscaleIP(host)

        let payload = PairingPayload(host: host, port: info.port, token: token, label: LocalComputerName.current())
        guard let url = PairingURLBuilder.makeURL(payload),
              let qrImage = QRCodeGenerator.makeImage(payload: url.absoluteString, size: PairingInfoStepLayout.qrSize) else {
            fail(.qrGenerationFailed)
            return
        }

        withAnimation(PairingInfoStepLayout.revealAnimation) {
            resolvedQRCode = qrImage
            state.pairingPayload = payload
            failureReason = nil
        }
    }

    @MainActor
    private func fail(_ reason: PairingFailureReason) {
        resolvedQRCode = nil
        state.pairingPayload = nil
        failureReason = reason
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    @MainActor
    private func copy(_ value: String, field: PairingCopyField) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)

        withAnimation(.snappy(duration: PairingInfoStepLayout.copyCheckInAnimationSeconds)) {
            copiedField = field
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: PairingInfoStepLayout.copyCheckHoldNanoseconds)
            guard copiedField == field else { return }
            withAnimation(.snappy(duration: PairingInfoStepLayout.copyCheckOutAnimationSeconds)) {
                copiedField = nil
            }
        }
    }
}

private enum PairingCopyField: Hashable {
    case tailscaleIP
    case port
    case pairingToken
    case serverName
}

private struct PairingResolvingSpinner: View {
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0.14, to: 0.82)
            .stroke(
                Color.tronEmerald,
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
            .frame(width: 34, height: 34)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                .linear(duration: PairingInfoStepLayout.spinnerRotationSeconds)
                    .repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = true
            }
    }
}

enum PairingInfoStepLayout {
    /// QR code rendered side dimension. Picked to fit alongside the
    /// info panel inside the shell's fixed-height content area.
    static let qrSize: CGFloat = 170
    static let columnSpacing: CGFloat = 20
    static let valueColumnWidth: CGFloat = 218
    static let clusterWidth: CGFloat = qrSize + columnSpacing + valueColumnWidth
    static let clusterHeight: CGFloat = qrSize
    static let valueCardVerticalPadding: CGFloat = 6
    static let valueCardHorizontalPadding: CGFloat = 12
    static let spinnerRotationSeconds = 0.82
    static let revealAnimation = Animation.timingCurve(0.18, 0.86, 0.24, 1.0, duration: 0.36)
    @MainActor
    static var revealTransition: AnyTransition {
        AnyTransition.opacity
            .combined(with: .scale(scale: 0.96, anchor: .center))
            .combined(with: .offset(y: 8))
    }
    /// Avoids the first fast refresh racing the shell's page-slide
    /// transition, which made the QR appear at its final coordinate
    /// before the rest of the step finished entering.
    static let initialResolveDelayNanoseconds: UInt64 = 500_000_000
    static let copyCheckInAnimationSeconds = 0.06
    static let copyCheckOutAnimationSeconds = 0.12
    static let copyCheckHoldNanoseconds: UInt64 = 2_000_000_000
}

struct PairingInfoWindowView: View {
    @State private var state = WizardState(initialStep: .pairingInfo)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pairing Info")
                .font(TronTypography.wizardTitle)
                .foregroundStyle(Color.tronEmerald)

            PairingInfoStep(state: state)
        }
        .padding(.horizontal, WizardLayout.horizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: WizardLayout.width, height: 360)
    }
}

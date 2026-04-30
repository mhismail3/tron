import SwiftUI
import AppKit

/// iOS beta handoff step. The shell owns Back / Continue; this view
/// presents the public TestFlight invite as a QR code so the user can
/// install the latest available Tron iOS beta on the phone before
/// moving to pairing.
struct IOSBetaStep: View {
    @State private var copiedLink = false

    private let qrImage = QRCodeGenerator.makeImage(
        payload: IOSBetaStepContent.testFlightURL.absoluteString,
        size: IOSBetaStepLayout.qrSize
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSBetaStepContent.intro)
                .font(TronTypography.wizardBodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: IOSBetaStepLayout.columnSpacing) {
                qrPanel
                infoPanel
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)
        }
        .animation(WizardLayout.transitionAnimation, value: copiedLink)
    }

    @ViewBuilder
    private var qrPanel: some View {
        ZStack {
            if let qrImage {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .overlay {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald.opacity(0.75))
                    Text("TestFlight link unavailable")
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
        }
        .frame(width: IOSBetaStepLayout.qrSize, height: IOSBetaStepLayout.qrSize)
        .wizardGlassCard()
    }

    @ViewBuilder
    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            scanCard

            linkCard
        }
        .frame(width: IOSBetaStepLayout.infoColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private var scanCard: some View {
        WizardInfoCard(horizontalPadding: IOSBetaStepLayout.cardHorizontalPadding) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: IOSBetaStepLayout.headerSpacing) {
                    Text(IOSBetaStepContent.scanHeadline)
                        .font(TronTypography.wizardSubheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)

                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .frame(
                            width: IOSBetaStepLayout.iconFrameSize,
                            height: IOSBetaStepLayout.iconFrameSize,
                            alignment: .trailing
                        )
                }

                Text(IOSBetaStepContent.scanBody)
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var linkCard: some View {
        WizardInfoCard(
            verticalPadding: 0,
            horizontalPadding: IOSBetaStepLayout.cardHorizontalPadding
        ) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(IOSBetaStepContent.linkLabel)
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)

                    Link(destination: IOSBetaStepContent.testFlightURL) {
                        Text(IOSBetaStepContent.displayLink)
                            .font(TronTypography.wizardCodeValue)
                            .foregroundStyle(Color.tronEmerald)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("Open TestFlight page")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, IOSBetaStepLayout.linkTextTopPadding)
                .padding(.bottom, IOSBetaStepLayout.linkTextBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    copyTestFlightLink()
                } label: {
                    Image(systemName: copiedLink ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .frame(
                            width: IOSBetaStepLayout.iconFrameSize,
                            height: IOSBetaStepLayout.iconFrameSize
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Copy TestFlight link")
            }
        }
    }

    @MainActor
    private func copyTestFlightLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(IOSBetaStepContent.testFlightURL.absoluteString, forType: .string)

        withAnimation(.snappy(duration: IOSBetaStepLayout.copyCheckInAnimationSeconds)) {
            copiedLink = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: IOSBetaStepLayout.copyCheckHoldNanoseconds)
            guard copiedLink else { return }
            withAnimation(.snappy(duration: IOSBetaStepLayout.copyCheckOutAnimationSeconds)) {
                copiedLink = false
            }
        }
    }
}

enum IOSBetaStepContent {
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/xbuX1Grx")!
    static let intro = "Install Tron iOS Beta on your iPhone before pairing. After TestFlight finishes installing Tron, return here and continue."
    static let scanHeadline = "Scan with your iPhone"
    static let scanBody = "Open Camera to scan this invite. If TestFlight is missing, Apple will send you to the App Store first."
    static let linkLabel = "Public TestFlight link"
    static let displayLink = "testflight.apple.com/join/xbuX1Grx"
}

enum IOSBetaStepLayout {
    static let qrSize: CGFloat = 170
    static let columnSpacing: CGFloat = 20
    static let infoColumnWidth: CGFloat = 218
    static let cardHorizontalPadding = WizardCardLayout.horizontalInset
    static let headerSpacing: CGFloat = 10
    static let iconFrameSize: CGFloat = 28
    static let linkTextTopPadding: CGFloat = 8
    static let linkTextBottomPadding: CGFloat = 6
    static let copyCheckInAnimationSeconds = 0.06
    static let copyCheckOutAnimationSeconds = 0.12
    static let copyCheckHoldNanoseconds: UInt64 = 2_000_000_000
}

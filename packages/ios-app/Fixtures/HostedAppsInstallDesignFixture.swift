#if HOSTED_TEST
import SwiftUI
import CryptoKit
import TronMobileCore

/// Approval-only composition. No RPC, persistence, displayed-artifact grant,
/// catalog, OS install or live feed is simulated as a successful operation.
struct HostedAppsInstallDesignFixture: View {
    @PresentationState private var launch: SwiftAppLaunch?
    @PresentationState private var review = false
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("-apps-design-dark") }
    private var source: String { ProcessInfo.processInfo.environment["TRON_APPS_DESIGN_SOURCE"] ?? "" }
    private var before: Bool { ProcessInfo.processInfo.arguments.contains("-apps-design-before") }

    var body: some View {
        TronPresentationSurface(id: "hosted-apps-install-design") {
            VStack(spacing: 24) {
                Text("Apps install design review").font(TronTypography.headline)
                Text("Synthetic data · No installation or saved changes").font(TronTypography.caption)
                Button("Open Builds preview") {
                    launch = SwiftAppLaunch(name: before ? "BuildsPreview.swift" : "BuildsInstallDesign.swift", source: source, linkHost: nil)
                }.accessibilityIdentifier("apps-install-design-open")
                Button("Review Install App") { review = true }
                    .accessibilityIdentifier("apps-install-design-review")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .tronManagedSheet(item: $launch, identity: { "apps.install.design.run.\($0.id)" }) { launch in
                SwiftAppRunnerSheet(launch: launch)
            }
            .tronManagedSheet(isPresented: $review, identity: "apps.install.design.review") {
                AppsInstallDesignReview(source: source)
            }
        }
        .tronPresentation()
        .preferredColorScheme(dark ? .dark : .light)
    }
}

private struct AppsInstallDesignReview: View {
    let source: String
    private var expanded: Bool { ProcessInfo.processInfo.arguments.contains("-apps-design-expanded") }
    private var digest: String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }

    var body: some View {
        TronDocumentSheet(title: "Install App", detents: [.medium, .large], initialDetent: expanded ? .large : .medium) {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                    TronSettingsGroup(nil) {
                        TronSettingsRow(icon: "shippingbox", title: "Builds", subtitle: "Paired Mac", subtitleColor: .tronTextSecondary) {
                            ResourceTagLabel(title: "Swift app", accent: .tronTextSecondary)
                        }
                    }
                    TronSettingsGroup("Access") {
                        VStack(spacing: 0) {
                            TronSettingsRow(icon: "dot.radiowaves.left.and.right", title: "iOS builds", subtitle: "Read-only feed", subtitleColor: .tronTextSecondary)
                            TronSettingsDivider(accent: .tronPrimary)
                            TronSettingsRow(icon: "link", title: "Install links", subtitle: "Paired Mac only", subtitleColor: .tronTextSecondary)
                        }
                    }
                    TronInfoCard(icon: "info.circle", text: "Builds reads the iOS builds feed when opened. Inside Builds, Install Build opens the selected manifest on your paired Mac; iOS asks before installing that build.")
                    TronSettingsGroup("Source") {
                        TronMetadataTable(accent: .tronPrimary, rows: [
                            .init(id: "source", title: "Artifact", value: "BuildsInstallDesign.swift"),
                            .init(id: "revision", title: "SHA-256", value: digest),
                            .init(id: "size", title: "Size", value: "\(source.utf8.count) bytes"),
                        ])
                    }
                    TronInfoCard(icon: "info.circle", text: "Design preview only. Install App keeps this Swift app and its data on your Mac. This action does not install an iOS build.")
                    TronPrimaryActionButton(title: "Install App", systemImage: "square.and.arrow.down", isEnabled: false) { }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .accessibilityIdentifier("apps-install-design-review-scroll")
        }
    }
}
#endif

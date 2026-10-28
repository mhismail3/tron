import SwiftUI

/// Uses the approved shared settings/metadata owners; no new sheet chrome or
/// source renderer. The retained Apps owner, never this view, owns installation.
struct SwiftAppInstallReviewSheet: View {
    let installation: SwiftAppInstallation
    let source: String
    let artifactName: String
    let profileID: String
    let openProblem: String?
    let onOpen: (InstalledSwiftAppManifest) -> Void
    @Environment(AppModel.self) private var model
    @PresentationState private var showsSource = false
    @PresentationState private var upgradesV1 = false
    @PresentationState private var problem: String?

    private var review: SwiftAppInstallReview { installation.review }
    private var updates: Bool { review.installed != nil }
    private var needsUpgrade: Bool { review.installed?.version == 1 }
    private var title: String { updates ? "Update App" : "Install App" }
    private var canStart: Bool {
        installation.command == nil && (!needsUpgrade || upgradesV1)
            && model.selectedGatewayProfileID() == profileID
    }

    var body: some View {
        TronDocumentSheet(title: title, detents: [.medium, .large], initialDetent: .medium) {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                    TronSettingsGroup(nil) {
                        TronSettingsRow(icon: review.offer.icon ?? "app", title: review.offer.name,
                            subtitle: "Paired Mac", subtitleColor: .tronTextSecondary) {
                            ResourceTagLabel(title: "Swift app", accent: .tronTextSecondary)
                        }
                    }
                    TronSettingsGroup("Access") {
                        if review.offer.feeds.contains("ios-builds") {
                            VStack(spacing: 0) {
                                TronSettingsRow(icon: "dot.radiowaves.left.and.right", title: "iOS builds", subtitle: "Read-only feed", subtitleColor: .tronTextSecondary)
                                TronSettingsDivider(accent: .tronPrimary)
                                TronSettingsRow(icon: "link", title: "Install links", subtitle: "Paired Mac only", subtitleColor: .tronTextSecondary)
                            }
                        } else {
                            TronSettingsRow(icon: "externaldrive", title: "App data", subtitle: "Stored on your paired Mac", subtitleColor: .tronTextSecondary)
                        }
                    }
                    if review.offer.feeds.contains("ios-builds") {
                        TronInfoCard(icon: "info.circle", text: "Builds reads the iOS builds feed when opened. Inside Builds, Install Build opens the selected manifest on your paired Mac; iOS asks before installing that build.")
                    }
                    TronSettingsGroup("Source") {
                        VStack(spacing: 0) {
                            TronMetadataTable(accent: .tronPrimary, rows: [
                                .init(id: "appId", title: "App ID", value: review.offer.appId),
                                .init(id: "installed", title: "Installed app", value: review.installed?.name ?? "Not installed"),
                                .init(id: "source", title: "Artifact", value: artifactName),
                                .init(id: "revision", title: "SHA-256", value: review.offer.sourceSha256),
                                .init(id: "size", title: "Size", value: "\(review.offer.sourceBytes) bytes"),
                            ])
                            Button("View Source") { showsSource = true }
                                .padding(12).accessibilityIdentifier("apps.install.source")
                        }
                    }
                    if updates {
                        TronInfoCard(icon: "externaldrive", text: "Update App replaces the reviewed source and declared access. Your existing app data stays on this Mac.")
                    }
                    if needsUpgrade {
                        Toggle("Back up and upgrade this app to manifest v2", isOn: $upgradesV1)
                            .disabled(installation.command != nil)
                            .accessibilityIdentifier("apps.install.upgrade")
                        TronInfoCard(icon: "info.circle", text: "This explicit update backs up the v1 source, manifest and app data before upgrading the manifest. The SQLite data format stays v1.")
                    }
                    if let failure = installation.failure ?? problem ?? openProblem {
                        TronInfoCard(icon: "exclamationmark.triangle", text: failure, accent: .tronAmber)
                            .accessibilityIdentifier("apps.install.error")
                    }
                    if let installed = installation.installed {
                        TronInfoCard(icon: "checkmark.circle", text: "\(installed.name) is installed on your Mac. This did not install an iOS build.")
                        TronPrimaryActionButton(title: "Open App", systemImage: "arrow.up.forward.app") { onOpen(installed) }
                            .accessibilityIdentifier("apps.install.open")
                    } else if installation.isInstalling {
                        TronLoadingState(label: "Confirming installation")
                            .accessibilityIdentifier("apps.install.pending")
                    } else {
                        TronInfoCard(icon: "info.circle", text: "Install App keeps this Swift app and its data on your Mac. This action does not install an iOS build.")
                        TronPrimaryActionButton(title: title, systemImage: "square.and.arrow.down", isEnabled: canStart) { start() }
                            .accessibilityIdentifier("apps.install.confirm")
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .accessibilityIdentifier("apps.install.review")
            .tronManagedSheet(isPresented: $showsSource, identity: "apps.install.source.\(review.offer.id)") {
                AttachmentFilePreviewSheet(name: artifactName, mimeType: "text/x-swift",
                    source: .local(id: review.offer.sourceSha256, data: Data(source.utf8)))
            }
        }
    }

    private func start() {
        guard canStart else { return }
        do {
            try model.installedApps.requireInstallCanStart(appID: review.offer.appId, profileID: profileID)
            installation.start(upgradeToV2: upgradesV1)
        } catch { problem = error.localizedDescription }
    }
}

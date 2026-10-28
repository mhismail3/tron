import SwiftUI

/// One Settings-style shell owns preparation and review, so resolving the offer
/// never replaces navigation chrome or changes the sheet's initial detent.
struct SwiftAppInstallReviewSheet: View {
    let installation: SwiftAppInstallation?
    let source: String
    let artifactName: String
    let profileID: String
    let openProblem: String?
    let onOpen: (InstalledSwiftAppManifest) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @PresentationState private var showsInfo = false
    @PresentationState private var upgradesV1 = false
    @PresentationState private var problem: String?

    private var accent: Color { TronSheetTint.resolve(nil, theme: settingsTheme) }
    private var title: String { installation?.review.installed != nil ? "Update App" : "Install App" }
    private var canStart: Bool {
        guard let installation else { return false }
        return installation.command == nil && (installation.review.installed?.version != 1 || upgradesV1)
            && model.selectedGatewayProfileID() == profileID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let installation {
                    reviewContent(installation)
                } else if let openProblem {
                    TronInfoCard(icon: "exclamationmark.triangle", text: openProblem, accent: .tronAmber)
                        .padding(18)
                        .accessibilityIdentifier("apps.install.error")
                } else {
                    TronSheetLoadingState(label: "Preparing Swift app…", accent: accent)
                }
            }
            .tronScrollEdgeChrome()
            .accessibilityIdentifier("apps.install.review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
            .toolbar(.hidden, for: .bottomBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TronSheetInfoButton(accessibilityLabel: "App technical information", accent: accent) { showsInfo = true }
                        .disabled(installation == nil)
                        .accessibilityIdentifier("apps.install.info")
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: title, accent: accent)
                        #if HOSTED_TEST
                        .onAppear { HostedInstallReviewObservation.documentAppeared(title) }
                        #endif
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(installation?.review.installed != nil ? "Update" : "Install") { start() }
                        .font(TronTypography.buttonSM)
                        .tronToolbarAction(accent: accent)
                        .disabled(!canStart)
                        .accessibilityIdentifier("apps.install.confirm")
                }
            }
        }
        .tint(accent)
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .tronManagedSheet(isPresented: $showsInfo, identity: "apps.install.info") {
            if let review = installation?.review {
                SwiftAppInstallDetailsSheet(review: review, source: source, artifactName: artifactName)
            }
        }
    }

    private func reviewContent(_ installation: SwiftAppInstallation) -> some View {
        let review = installation.review
        let updates = review.installed != nil
        return TronSettingsSections(alignment: .leading, spacing: TronSpacing.section, hidesLoneHeading: true) {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                TronSettingsGroup(nil) {
                    TronSettingsRow(icon: review.offer.icon ?? "app", title: review.offer.name,
                        subtitle: "Runs on your iPhone", subtitleColor: .tronTextSecondary) {
                        ResourceTagLabel(title: "Swift app", accent: .tronTextSecondary)
                    }
                }
                TronSettingsCaption(updates
                    ? "Updates the app on your Mac. Your app data stays."
                    : "Installs on your Mac. This doesn’t install an iOS build.")
            }
            VStack(alignment: .leading, spacing: TronSpacing.md) {
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
                    TronSettingsCaption("\(review.offer.name) reads your iOS builds feed when opened.")
                }
            }
            if review.installed?.version == 1 {
                Toggle("Back up and upgrade this app to manifest v2", isOn: $upgradesV1)
                    .disabled(installation.command != nil)
                    .accessibilityIdentifier("apps.install.upgrade")
                TronSettingsCaption("Backs up the source, manifest and app data before upgrading. The data format stays v1.")
            }
            if let failure = installation.failure ?? problem ?? openProblem {
                TronInfoCard(icon: "exclamationmark.triangle", text: failure, accent: .tronAmber)
                    .accessibilityIdentifier("apps.install.error")
            }
            if let installed = installation.installed {
                TronSettingsCaption("\(installed.name) is installed on your Mac. No iOS build was installed.")
                TronPrimaryActionButton(title: "Open App", systemImage: "arrow.up.forward.app") { onOpen(installed) }
                    .accessibilityIdentifier("apps.install.open")
            } else if installation.isInstalling {
                TronLoadingState(label: "Confirming installation")
                    .accessibilityIdentifier("apps.install.pending")
            }
        }
        .padding(18)
    }

    private func start() {
        guard canStart, let installation else { return }
        do {
            try model.installedApps.requireInstallCanStart(appID: installation.review.offer.appId, profileID: profileID)
            installation.start(upgradeToV2: upgradesV1)
        } catch { problem = error.localizedDescription }
    }
}

private struct SwiftAppInstallDetailsSheet: View {
    let review: SwiftAppInstallReview
    let source: String
    let artifactName: String
    @PresentationState private var showsSource = false

    var body: some View {
        TronDocumentSheet(title: "App Details", detents: [.medium, .large], initialDetent: .medium) {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: TronSpacing.section, hidesLoneHeading: true) {
                    TronSettingsGroup("Details") {
                        TronMetadataTable(accent: .tronPrimary, rows: [
                            .init(id: "appId", title: "App ID", value: review.offer.appId),
                            .init(id: "installed", title: "Installed app", value: review.installed?.name ?? "Not installed"),
                            .init(id: "source", title: "Artifact", value: artifactName),
                            .init(id: "revision", title: "SHA-256", value: review.offer.sourceSha256),
                            .init(id: "size", title: "Size", value: "\(review.offer.sourceBytes) bytes"),
                        ])
                    }
                    TronSettingsGroup(nil) {
                        Button { showsSource = true } label: {
                            TronSettingsRow(icon: "doc.text", title: "View Source") {
                                Image(systemName: "chevron.right").foregroundStyle(Color.tronTextSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("apps.install.source")
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .accessibilityIdentifier("apps.install.details")
            .tronManagedSheet(isPresented: $showsSource, identity: "apps.install.source.\(review.offer.id)") {
                AttachmentFilePreviewSheet(name: artifactName, mimeType: "text/x-swift",
                    source: .local(id: review.offer.sourceSha256, data: Data(source.utf8)))
            }
        }
    }
}

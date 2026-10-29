import SwiftUI

/// The Tron menu's Apps sheet: catalog entries, opened in
/// the shared runner with their persisted values. It composes the same shared
/// document sheet, list rows and settings rows the approved design used; the
/// catalog and every write belong to `InstalledSwiftApps`.
struct InstalledAppsSheet: View {
    @Environment(AppModel.self) private var model
    @PresentationState private var managed: InstalledSwiftAppManifest?
    @PresentationState private var launch: SwiftAppLaunch?
    @PresentationState private var openError: String?

    private var apps: InstalledSwiftApps { model.installedApps }
    private var profileID: String? { model.selectedGatewayProfileID() }

    var body: some View {
        TronDocumentSheet(title: "Apps", detents: [.medium, .large], initialDetent: .medium) {
            ScrollView {
                TronSettingsSections(hidesLoneHeading: true) {
                    if let openError { TronInfoCard(icon: "exclamationmark.triangle", text: openError, accent: .tronAmber) }
                    switch apps.phase {
                    case .idle, .loading where apps.isEmpty:
                        TronLoadingState(label: "Loading apps")
                    case .failed(let message) where apps.isEmpty:
                        TronInfoCard(icon: "exclamationmark.triangle", text: "Apps could not be loaded. \(message)", accent: .tronAmber)
                            .accessibilityIdentifier("installed-apps-error")
                    default:
                        if apps.isEmpty {
                            TronInfoCard(icon: "square.grid.2x2", text: "No apps are installed on this Mac yet. Ask Tron to build one and install it.")
                                .accessibilityIdentifier("installed-apps-empty")
                        } else {
                            if case .failed(let message) = apps.phase {
                                TronInfoCard(icon: "exclamationmark.triangle", text: "Showing the last list. \(message)", accent: .tronAmber)
                            }
                            if !apps.apps.isEmpty {
                                TronListGroup(sections: [.init(title: "Installed", rows: apps.apps, tint: .tronPrimary)],
                                              hasLeading: true, identifier: "installed-apps-group") { app in row(app) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            .tronScrollEdgeChrome()
            .refreshable { await reload() }
            .task { await reload() }
            .tronManagedSheet(item: $managed, identity: { "apps.manage.\($0.id)" }) { app in
                InstalledAppManageSheet(appID: app.id)
            }
            .tronManagedSheet(item: $launch, identity: { "apps.run.\($0.id)" }) { launch in
                SwiftAppRunnerSheet(launch: launch)
            }
        }
        .onChange(of: launch == nil) { _, closed in
            // The catalog is a projection; a closed runner or Manage may have changed it.
            if closed { Task { await reload() } }
        }
    }

    private func row(_ app: InstalledSwiftAppManifest) -> some View {
        TronListButton(
            TronListRowContent(leading: .icon(app.icon ?? "app", .tronPrimary), title: app.name,
                               subtext: "Source revision \(app.revision)", tags: tags(app),
                               accessibilityHint: "Opens the app. Touch and hold for Open and Manage."),
            identifier: "installed-app-row-\(app.id)", action: { open(app) }
        ) {
            Button("Open", systemImage: "arrow.up.forward.app") { open(app) }
            Button("Manage", systemImage: "slider.horizontal.3") { managed = app }
        }
    }

    private func tags(_ app: InstalledSwiftAppManifest) -> [TronListTag] {
        var tags = [TronListTag(text: "Swift app")]
        if let profileID, apps.hasUnsavedChanges(appID: app.id, profileID: profileID) { tags.append(TronListTag(text: "Unsaved")) }
        return tags
    }

    private func reload() async {
        guard let profileID else { return }
        await apps.reload(profileID: profileID)
    }

    private func open(_ app: InstalledSwiftAppManifest) {
        guard let profileID else { return }
        openError = nil
        Task {
            do {
                let session = try await apps.open(appID: app.id, profileID: profileID)
                launch = SwiftAppLaunch(session: session, linkHost: model.profiles.selected?.host)
            } catch is CancellationError {
            } catch {
                openError = "\(app.name) could not be opened. \(error.localizedDescription)"
                await reload()
            }
        }
    }
}

extension InstalledSwiftAppManifest: Identifiable {}

/// Rename and clear saved values. Destructive actions confirm
/// first; failures stay visible instead of being dropped.
private struct Notice: Equatable { let message: String; let failed: Bool }

private struct InstalledAppManageSheet: View {
    let appID: String
    @Environment(AppModel.self) private var model
    @PresentationState private var renaming = false
    @PresentationState private var confirmingReset = false
    @PresentationState private var confirmingDiscard = false
    @PresentationState private var name = ""
    @PresentationState private var notice: Notice?
    @PresentationState private var working = false

    private var app: InstalledSwiftAppManifest? { model.installedApps.apps.first { $0.id == appID } }
    private var profileID: String? { model.selectedGatewayProfileID() }
    private var hasUnsaved: Bool { profileID.map { model.installedApps.hasUnsavedChanges(appID: appID, profileID: $0) } ?? false }

    var body: some View {
        TronDocumentSheet(title: "Manage App", detents: [.medium, .large], initialDetent: .medium) {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                    if let notice { TronSettingsNotice(message: notice.message, accent: notice.failed ? .tronAmber : .tronPrimary) }
                    if let app {
                        TronSettingsGroup(nil) {
                            TronSettingsRow(icon: app.icon ?? "app", title: app.name, subtitle: "Source revision \(app.revision) · Stored on your Mac",
                                            subtitleColor: .tronTextSecondary) {
                                ResourceTagLabel(title: "Swift app", accent: .tronTextSecondary)
                            }
                        }
                        TronSettingsGroup(nil) {
                            VStack(spacing: 0) {
                                action("pencil", "Rename", "Change the name shown in Apps.", id: "rename") {
                                    name = app.name; renaming = true
                                }
                                if hasUnsaved {
                                    TronSettingsDivider(accent: .tronPrimary)
                                    action("exclamationmark.arrow.triangle.2.circlepath", "Discard Unsaved Changes",
                                           "Give up changes that could not be saved and reload from your Mac.", id: "discard") {
                                        confirmingDiscard = true
                                    }
                                }
                                TronSettingsDivider(accent: .tronPrimary)
                                action("arrow.counterclockwise", "Clear Data", "Delete this app's saved values. Its source stays.", id: "reset") {
                                    confirmingReset = true
                                }
                            }
                        }
                    } else {
                        TronInfoCard(icon: "questionmark.circle", text: "This app is no longer installed.")
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
        }
        .tronConfirmation("Rename App", isPresented: $renaming) {
            TronConfirmationTextField(placeholder: "Name", text: $name) { run { try await $0.rename(appID: appID, profileID: $1, to: name) } }
            Button("Save") { run { try await $0.rename(appID: appID, profileID: $1, to: name) } }
        }
        .tronConfirmation("Discard unsaved changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) {
                if let profileID { model.installedApps.discardUnsaved(appID: appID, profileID: profileID) }
                notice = Notice(message: "Unsaved changes discarded.", failed: false)
            }
        } message: {
            Text("Changes this app could not save to your Mac are deleted from this iPhone.")
        }
        .tronConfirmation("Clear this app's data?", isPresented: $confirmingReset) {
            Button("Clear Data", role: .destructive) { run(done: "Data cleared.") { try await $0.resetData(appID: appID, profileID: $1) } }
        } message: {
            Text("Saved values are deleted from your Mac and cannot be restored. The app and its source stay installed.")
        }
    }

    private func action(_ icon: String, _ title: String, _ subtitle: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleColor: .tronTextSecondary)
        }
        .buttonStyle(.plain)
        .disabled(working)
        .accessibilityIdentifier("installed-app-manage-\(id)")
    }

    private func run(done: String? = nil,
                     _ work: @escaping @MainActor (InstalledSwiftApps, String) async throws -> Void) {
        guard let profileID, !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                try await work(model.installedApps, profileID)
                notice = done.map { Notice(message: $0, failed: false) }
            } catch is CancellationError {
            } catch {
                notice = Notice(message: error.localizedDescription, failed: true)
            }
        }
    }
}

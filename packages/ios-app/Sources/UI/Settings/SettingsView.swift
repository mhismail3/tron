import SwiftUI

struct SettingsView: View {
    enum Scope { case dashboard, project }

    let scope: Scope
    let projectSessionID: String?
    let projectCWD: String?
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        scope: Scope = .dashboard,
        projectSessionID: String? = nil,
        projectCWD: String? = nil,
        onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }
    ) {
        self.scope = scope
        self.projectSessionID = scope == .project ? projectSessionID : nil
        self.projectCWD = scope == .project ? projectCWD : nil
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    TronSettingsGroup("App") {
                        VStack(spacing: 0) {
                            settingsLink("Appearance", icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Connections", icon: "desktopcomputer") { ConnectionsSettingsView() }
                        }
                    }
                    TronSettingsGroup("Agent") {
                        VStack(spacing: 0) {
                            settingsLink("Providers", icon: "key") {
                                ProvidersSettingsView(sessionID: projectSessionID)
                            }
                            TronSettingsDivider()
                            settingsLink("Models and Defaults", icon: "cpu") {
                                AgentDefaultsSettingsView(
                                    allowsProjectScope: scope == .project,
                                    providerTarget: projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global,
                                    projectCWD: projectCWD
                                )
                            }
                            TronSettingsDivider()
                            settingsLink("Runtime Behavior", icon: "gearshape.2") {
                                RuntimeBehaviorSettingsView(projectCWD: projectCWD)
                            }
                            TronSettingsDivider()
                            settingsLink("Resource Paths", icon: "folder.badge.gearshape") {
                                ResourceSettingsView(projectCWD: projectCWD)
                            }
                            TronSettingsDivider()
                            settingsLink("Packages and Resources", icon: "shippingbox") {
                                PackagesSettingsView(projectCWD: projectCWD)
                            }
                            if scope == .project {
                                TronSettingsDivider()
                                settingsLink("Project Trust", icon: "checkmark.shield") {
                                    TrustSettingsView(
                                        target: projectCWD.flatMap(TrustTarget.init(cwd:))
                                    )
                                }
                            }
                            TronSettingsDivider()
                            settingsLink("Custom Models", icon: "slider.horizontal.3") { CustomModelsSettingsView() }
                        }
                    }
                    TronSettingsGroup("Gateway") {
                        VStack(spacing: 0) {
                            if scope == .dashboard {
                                settingsLink("Import", icon: "tray.and.arrow.down") {
                                    ImportSettingsView(onImported: onImported)
                                }
                                TronSettingsDivider()
                            }
                            settingsLink("Diagnostics", icon: "stethoscope") { GatewayDiagnosticsView() }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Settings") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: dynamicTypeSize.isAccessibilitySize ? "xmark" : "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                            .accessibilityLabel("Done")
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
        .gatewayGlobalSheets()
        .task {
            await model.refreshAll(
                settingsTarget: projectCWD.map(SettingsTarget.project(cwd:)) ?? .global,
                providerTarget: projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
            )
        }
        .tronPresentation()
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronSettingsRow(icon: icon, title: title)
                .contentShape(Rectangle())
        }
    }
}

struct TronProgressiveSheetLink<Label: View, Destination: View>: View {
    let accessibilityLabel: String
    /// Keep destination construction inside the presented sheet so large
    /// settings payloads are not built while the parent sheet is scrolling.
    let destination: () -> Destination
    let label: Label
    @State private var isPresented = false

    init(
        accessibilityLabel: String,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    destination()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { isPresented = false } label: {
                                    Image(systemName: "checkmark")
                                        .font(TronTypography.buttonSM)
                                        .foregroundStyle(Color.tronEmerald)
                                }
                                .accessibilityLabel("Done")
                            }
                        }
                }
                .tronTopBlur(.sheet)
                .tronPresentation()
                .presentationDragIndicator(.hidden)
            }
    }
}

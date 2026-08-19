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
                VStack(spacing: 12) {
                    settingsLink(
                        "Appearance",
                        summary: "Theme, type scale, and visual preferences",
                        icon: "circle.lefthalf.filled"
                    ) { AppearanceSettingsView() }
                    settingsLink(
                        "Connections",
                        summary: "Pair and manage Mac gateways",
                        icon: "desktopcomputer"
                    ) { ConnectionsSettingsView() }
                    settingsLink(
                        "Providers",
                        summary: "Authentication and provider credentials",
                        icon: "key"
                    ) {
                        ProvidersSettingsView(sessionID: projectSessionID)
                    }
                    settingsLink(
                        "Models and Defaults",
                        summary: "Default model, thinking, and selection policy",
                        icon: "cpu"
                    ) {
                        AgentDefaultsSettingsView(
                            allowsProjectScope: scope == .project,
                            providerTarget: projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global,
                            projectCWD: projectCWD
                        )
                    }
                    settingsLink(
                        "Runtime Behavior",
                        summary: "Prompt queue, retries, and compaction behavior",
                        icon: "gearshape.2"
                    ) {
                        RuntimeBehaviorSettingsView(projectCWD: projectCWD)
                    }
                    settingsLink(
                        "Resource Paths",
                        summary: "Instructions, skills, and project resources",
                        icon: "folder.badge.gearshape"
                    ) {
                        ResourceSettingsView(projectCWD: projectCWD)
                    }
                    settingsLink(
                        "Packages and Resources",
                        summary: "Installed packages and executable resources",
                        icon: "shippingbox"
                    ) {
                        PackagesSettingsView(projectCWD: projectCWD)
                    }
                    if scope == .project {
                        settingsLink(
                            "Project Trust",
                            summary: "Review executable workspace resource trust",
                            icon: "checkmark.shield"
                        ) {
                            TrustSettingsView(
                                target: projectCWD.flatMap(TrustTarget.init(cwd:))
                            )
                        }
                    }
                    settingsLink(
                        "Custom Models",
                        summary: "Saved model definitions and aliases",
                        icon: "slider.horizontal.3"
                    ) { CustomModelsSettingsView() }
                    if scope == .dashboard {
                        settingsLink(
                            "Import",
                            summary: "Restore a session export",
                            icon: "tray.and.arrow.down"
                        ) {
                            ImportSettingsView(onImported: onImported)
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
        summary: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronGlassCard(accent: .tronEmerald) {
                TronSettingsRow(
                    icon: icon,
                    title: title,
                    subtitle: summary,
                    subtitleLineLimit: 2,
                    subtitleColor: .tronTextSecondary
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

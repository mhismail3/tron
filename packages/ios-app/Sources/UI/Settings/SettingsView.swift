import SwiftUI
import TronMobileCore

struct SettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var showsNotifications = false
    @PresentationState private var hasRefreshedNotificationBadge = false

    init(onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }) {
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    SettingsGroupCard(.iphone) {
                        settingsLink("Appearance", summary: "Dashboard, activity, theme, and fonts",
                                     icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                    }
                    SettingsGroupCard(.accounts) {
                        settingsLink("Connections", summary: "Paired Macs and authorized devices", icon: "desktopcomputer") {
                            ConnectionsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Model Providers", summary: "Provider accounts and sign-in", icon: "key") {
                            ProvidersSettingsView(sessionID: nil)
                        }
                    }
                    SettingsGroupCard(.tools) {
                        settingsLink("MCP Servers", summary: "Tool providers and their sign-ins", icon: "server.rack") {
                            MCPServersSettingsView()
                        }
                    }
                    SettingsGroupCard(.diagnostics) {
                        MacTerminalSettingsRow()
                        TronSettingsDivider()
                        settingsLink("Setup", summary: "Import, session storage, telemetry, and prototypes", icon: "gearshape.2") {
                            SetupSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Logs", summary: "Diagnostics from this iPhone and your Macs", icon: "text.alignleft") {
                            GatewayLogsSettingsView()
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    NotificationInboxToolbarButton(
                        unreadCount: model.notificationInbox.unreadCount,
                        action: { showsNotifications = true }
                    )
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Global Settings") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: dynamicTypeSize.isAccessibilitySize ? "xmark" : "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronPrimary)
                            .accessibilityLabel("Done")
                    }
                    .accessibilityIdentifier("settings-done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronManagedSheet(
            isPresented: $showsNotifications,
            identity: "settings.notifications"
        ) {
            NotificationInboxView(onOpenSession: onImported)
        }
        .task(id: PresentationActivityTaskID(source: model.settingsFreshness,
                                             presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            try? await model.refreshSettingsSnapshot(for: SettingsTarget.global.gatewayTarget)
        }
        .task(id: presentationActivity.allowsPresentationPublication) {
            guard presentationActivity.allowsPresentationPublication,
                  !hasRefreshedNotificationBadge else { return }
            await model.refreshNotificationInbox()
            guard !Task.isCancelled else { return }
            hasRefreshedNotificationBadge = true
        }
        .tronPresentation()
        .tronSettingsLayout()
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        summary: String,
        icon: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, onDismiss: onDismiss, destination: destination) {
            TronSettingsRow(icon: icon, title: title, subtitle: summary, subtitleColor: .tronTextSecondary)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("settings-link-\(title)")
    }
}

enum SettingsGroupKind {
    case tools, accounts, more, iphone, diagnostics

    var title: String {
        switch self {
        case .tools: "Agent & Tools"
        case .accounts: "Accounts"
        case .more: "More"
        case .iphone: "This iPhone"
        case .diagnostics: "System"
        }
    }

    @MainActor var accent: Color {
        switch self {
        case .tools, .accounts, .more, .iphone: .tronPrimary
        case .diagnostics: .tronSteel
        }
    }

    static let placedSections: Set<String> = ["model", "workers", "context", "run", "trust", "notifications", "connections", "tools", "sources"]

    static func icon(forSection id: String) -> String {
        switch id {
        case "model": "cpu"
        case "context": "rectangle.compress.vertical"
        case "run": "arrow.clockwise"
        case "workers": "person.2"
        case "advanced": "gearshape.2"
        case "tools": "wrench.and.screwdriver"
        case "sources": "shippingbox"
        default: "slider.horizontal.3"
        }
    }
}

struct SettingsGroupCard<Content: View>: View {
    let kind: SettingsGroupKind
    @ViewBuilder let content: () -> Content

    init(_ kind: SettingsGroupKind, @ViewBuilder content: @escaping () -> Content) {
        self.kind = kind; self.content = content
    }

    var body: some View {
        TronSettingsGroup(kind.title, accent: kind.accent) { content() }
            .tronSettingsVisualTheme(accent: kind.accent)
    }
}

struct SetupSettingsView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) {
                ExperimentalSettingsContent()
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Setup")
    }
}

enum TronSheetDetentPolicy {
    case fixed(Set<PresentationDetent>)
    case contentFit
}

private struct TronSheetDetentPolicyModifier: ViewModifier {
    let policy: TronSheetDetentPolicy

    func body(content: Content) -> some View {
        switch policy {
        case .fixed(let detents): content.presentationDetents(detents)
        case .contentFit: content.tronContentFitDetents()
        }
    }
}

struct TronProgressiveSheetLink<Label: View, Destination: View>: View {
    let accessibilityLabel: String
    let identity: String
    let destination: () -> Destination
    let label: Label
    let accent: Color?
    let surfaceAccent: Color?
    let detents: TronSheetDetentPolicy
    let onDismiss: (() -> Void)?
    private let fileID: String
    private let line: Int
    @PresentationState private var isPresented: Bool
    @Environment(\.tronSettingsVisualTheme) private var inheritedTheme

    init(
        accessibilityLabel: String,
        identity: String? = nil,
        accent: Color? = nil,
        surfaceAccent: Color? = nil,
        detents: TronSheetDetentPolicy = .fixed([.medium, .large]),
        onDismiss: (() -> Void)? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.fileID = fileID
        self.line = line
        self.accessibilityLabel = accessibilityLabel
        self.identity = identity ?? "settings.\(accessibilityLabel)"
        _isPresented = PresentationState(wrappedValue: false, key: "\(self.identity)@\(fileID):\(line)")
        self.accent = accent
        self.surfaceAccent = surfaceAccent
        self.detents = detents
        self.onDismiss = onDismiss
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .tronManagedSheet(
                isPresented: $isPresented,
                identity: identity,
                onDismiss: onDismiss,
                fileID: fileID,
                line: line
            ) {
                NavigationStack {
                    themed(destination()
                        .environment(\.tronSettingsRowAccessory, nil)
                        .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { isPresented = false } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .tronToolbarAction()
                            }
                            .accessibilityLabel("Done")
                        }
                    })
                }
                .tronTopBlur(.sheet)
                .tronPresentation()
                .tronSettingsLayout()
                .modifier(TronSheetDetentPolicyModifier(policy: detents))
                .presentationDragIndicator(.hidden)
            }
    }

    @ViewBuilder
    private func themed(_ content: some View) -> some View {
        if let accent {
            content.tronSettingsVisualTheme(accent: accent, surfaceAccent: surfaceAccent)
        } else if let inheritedTheme {
            content.environment(\.tronSettingsVisualTheme, inheritedTheme).tint(inheritedTheme.accent)
        } else {
            content
        }
    }
}

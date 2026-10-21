#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Design-only simulator preview for #1634. Values and edits are synthetic;
/// production resolution, receipts and migration are deliberately not simulated.
@MainActor
struct HostedSettingsThreeLayerPreview: View {
    let surface: String
    @State private var previewPresented = true
    @State private var previewDetent: PresentationDetent = .large
    @State private var scope = "All scopes"
    @State private var actor = "Everyone"
    @State private var group = "Any group"
    @State private var time = "Any time"
    @State private var key = ""
    @State private var overridden = true
    @State private var retry = true

    private var home: Bool { surface.contains("home") }

    var body: some View {
        Color.clear.tronManagedSheet(isPresented: $previewPresented, identity: "preview.settings.\(surface)") {
            Group {
                if surface == "global" {
                    previewContent
                } else {
                    NavigationStack {
                        previewContent.toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { previewPresented = false } label: {
                                    Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction()
                                }
                                .accessibilityLabel("Done")
                            }
                        }
                    }
                }
            }
            .tronTopBlur(.sheet)
            .tronPresentation()
            .tronSettingsLayout()
            .presentationDetents([.medium, .large], selection: $previewDetent)
            .presentationDragIndicator(.hidden)
        }
    }

    private var previewContent: some View {
        Group {
            switch surface {
            case "global": SettingsView()
            case "changes": changes
            case "manage-session", "manage-home": manage
            case "session", "home": settings
            case "project-row": projectRows
            case "project-only": projectOnly
            default: settings
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Design preview · Synthetic values")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
    }

    private func page<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .tronSettingsLayout()
    }

    private func link<Content: View>(_ title: String, _ subtitle: String, _ icon: String,
                                     @ViewBuilder destination: @escaping () -> Content) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle)
        }
    }

    private var manage: some View {
        page(home ? "Manage Home" : "Manage Session") {
            TronSettingsGroup(home ? "Home" : "Session", accent: .tronSessionTeal) {
                TronSettingsRow(icon: home ? "house" : "bubble.left", title: home ? "Home" : "Settings redesign",
                                subtitle: home ? "Your assistant profile" : "Tron · main")
                TronSettingsDivider()
                link(home ? "Home Settings" : "Session Settings", "Defaults and overrides", "slider.horizontal.3") { settings }
            }
            if !home {
                TronSettingsGroup("Conversation") {
                    TronSettingsRow(icon: "doc.text.magnifyingglass", title: "Agent Instructions", subtitle: "The assembled instructions")
                    TronSettingsDivider()
                    TronSettingsRow(icon: "clock.arrow.circlepath", title: "Session History", subtitle: "Review history, continue, or fork")
                    TronSettingsDivider()
                    TronSettingsRow(icon: "rectangle.compress.vertical", title: "Compact conversation", subtitle: "Summarize older context now")
                }
            }
        }
    }

    private var settings: some View {
        page(home ? "Home Settings" : "Session Settings") {
            SettingsGroupCard(.agent) {
                link("Models", "Models, thinking, and workers", "cpu") { modelRows }
                if !home {
                    TronSettingsDivider()
                    link("Compaction", "Automatic summaries and retained context", "rectangle.compress.vertical") { compaction }
                }
                TronSettingsDivider()
                link("More Settings", "Connection, queues, and retries", "gearshape.2") { runRows }
            }
            SettingsGroupCard(.tools) {
                link("Tools", "Available tools and image handling", "wrench.and.screwdriver") { tools }
            }
            if !home {
                TronSettingsGroup(nil) {
                    link("Set by Project", "2 repository settings", "folder.badge.gearshape") { projectOnly }
                }
            }
        }
    }

    private var modelRows: some View {
        page("Models") {
            TronSettingsGroup("Model") {
                if home {
                    TronSettingsRow(icon: "cpu", title: "Model") { Text("GPT-6.1 Sol").foregroundStyle(Color.tronTextSecondary) }
                } else { projectModel }
                TronSettingsDivider()
                overrideRow("Thinking", value: overridden ? "High" : "Medium")
                TronSettingsDivider()
                TronSettingsRow(icon: "number", title: "Context window") { Text("200K tokens").foregroundStyle(Color.tronTextSecondary) }
            }
            if home {
                TronSettingsGroup("Workers & delegation", detail: "Changes apply to new workers. Running workers keep their admitted choices.") {
                    TronSettingsRow(icon: "person.2", title: "Worker models") { Text("2 models").foregroundStyle(Color.tronTextSecondary) }
                    TronSettingsDivider()
                    TronSettingsRow(icon: "slider.horizontal.3", title: "Worker thinking") { Text("High").foregroundStyle(Color.tronTextSecondary) }
                    TronSettingsDivider()
                    TronSettingsRow(icon: "list.bullet", title: "Subagent models") { Text("3 models").foregroundStyle(Color.tronTextSecondary) }
                }
            }
        }
    }

    private func overrideRow(_ title: String, value: String) -> some View {
        TronSettingsRow(icon: "slider.horizontal.3", title: title) {
            HStack(spacing: 8) {
                Text(value).foregroundStyle(Color.tronTextSecondary)
                if overridden {
                    TronStatusPill(text: "Overridden", accent: .tronPurple)
                    Button { overridden = false } label: {
                        TronInlineActionLabel("", icon: "arrow.uturn.backward", accent: .tronPurple)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Revert")
                }
            }
        }
    }

    private var projectModel: some View {
        TronSettingsRow(icon: "cpu", title: "Model") {
            VStack(alignment: .trailing, spacing: 6) {
                Text("GPT-6.1 Sol").foregroundStyle(Color.tronTextSecondary)
                TronProgressiveSheetLink(accessibilityLabel: "Set by Project settings",
                                         identity: "preview.project-setting-info", detents: .fixed([.height(300), .medium])) {
                    projectInfo
                } label: {
                    TronInlineActionLabel("Set by Project settings")
                        .controlSize(.small)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("preview-project-pill")
            }
        }
    }

    private var projectRows: some View {
        page("Models") {
            TronSettingsGroup("Model", detail: "Changes apply from the next turn.") {
                projectModel
                TronSettingsDivider()
                overrideRow("Thinking", value: overridden ? "High" : "Medium")
                TronSettingsDivider()
                TronSettingsRow(icon: "number", title: "Context window") { Text("200K tokens").foregroundStyle(Color.tronTextSecondary) }
            }
        }
    }

    private var projectInfo: some View {
        page("Project setting") {
            TronSettingsCaption("This is set by the current project's settings. Ask an agent to update them in the repo.")
            TronSettingsGroup(nil) {
                TronSettingsRow(icon: "doc.text", title: "File") { Text(".pi/settings.json").font(TronTypography.secondaryCodeDescription).textSelection(.enabled) }
                TronSettingsDivider()
                TronSettingsRow(icon: "key", title: "Key") { Text("defaultProvider + defaultModel").font(TronTypography.secondaryCodeDescription).textSelection(.enabled) }
            }
        }
    }

    private var projectOnly: some View {
        page("Set by Project") {
            TronSettingsCaption("Read-only values from .pi/settings.json. Ask an agent to update them in the repo.")
            TronSettingsGroup("Models") {
                TronSettingsRow(icon: "list.bullet", title: "Offered models") { Text("4 models").foregroundStyle(Color.tronTextSecondary) }
            }
            TronSettingsGroup("Tools") {
                TronSettingsRow(icon: "terminal", title: "Shell", subtitle: "Applies to a new session") {
                    Text("/bin/bash").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary)
                }
            }
        }
    }

    private var compaction: some View {
        page("Compaction") {
            TronSettingsGroup("Compaction", detail: "Changes apply at the next compaction.") {
                TronSettingsRow(icon: "switch.2", title: "Automatic compaction") { Toggle("Automatic compaction", isOn: $retry).labelsHidden() }
                TronSettingsDivider()
                TronSettingsRow(icon: "number", title: "Response reserve") { Text("16K tokens").foregroundStyle(Color.tronTextSecondary) }
                TronSettingsDivider()
                TronSettingsRow(icon: "number", title: "Kept after compaction") { Text("20K tokens").foregroundStyle(Color.tronTextSecondary) }
            }
        }
    }

    private var runRows: some View {
        page("More Settings") {
            TronSettingsGroup("Connection", detail: "Changes apply from the next request.") {
                TronSettingsRow(icon: "network", title: "Transport") { Text("Automatic").foregroundStyle(Color.tronTextSecondary) }
            }
            TronSettingsGroup("Retry") {
                TronSettingsRow(icon: "switch.2", title: "Retry") { Toggle("Retry", isOn: $retry).labelsHidden() }
                TronSettingsDivider()
                overrideRow("Retries", value: "3 retries")
            }
        }
    }

    private var tools: some View {
        page("Tools") {
            TronSettingsGroup("Tools") {
                TronSettingsRow(icon: "checklist", title: "Available tools") { Text(home ? "14 tools" : "8 tools").foregroundStyle(Color.tronTextSecondary) }
            }
            TronSettingsGroup("Images") {
                TronSettingsRow(icon: "photo", title: "Resize images", subtitle: "Applies to a new session") { Toggle("Resize images", isOn: $retry).labelsHidden() }
            }
        }
    }

    private var changes: some View {
        page("Changes") {
            TronSettingsCaption("All scopes · Global, sessions, and Home profile")
            ForEach(Array([("Model", "Global", "You", "Fixture Lite → GPT-6.1 Sol"),
                           ("Thinking", "Settings redesign", "Home · task 1634", "Medium → High"),
                           ("Worker models", "Home profile", "Home", "1 model → 2 models")].enumerated()), id: \.offset) { _, item in
                TronSettingsGroup(nil) {
                    TronSettingsRow(icon: "clock.arrow.circlepath", title: item.0, subtitle: "\(item.1) · \(item.2) · Today, 12:30") {
                        Button {} label: { TronInlineActionLabel("", icon: "arrow.uturn.backward") }
                            .buttonStyle(.plain).accessibilityLabel("Undo")
                    }
                    Text(item.3).font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextSecondary).padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronProgressiveSheetLink(accessibilityLabel: "Filters", identity: "preview.changes-filters") {
                    filters
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(TronTypography.buttonSM).tronToolbarAction()
                }
                .accessibilityIdentifier("preview-changes-filters")
            }
        }
    }

    private var filters: some View {
        page("Filters") {
            TronSettingsGroup("Changes") {
                filter("Scope", icon: "square.3.layers.3d", choices: ["All scopes", "Global", "Home profile", "Settings redesign · session 1634", "Legacy Project"], selection: $scope)
                TronSettingsDivider()
                filter("Actor", icon: "person", choices: ["Everyone", "You", "Home", "Worker tasks"], selection: $actor)
                TronSettingsDivider()
                filter("Group", icon: "square.grid.2x2", choices: ["Any group", "Model", "Workers & delegation", "Compaction", "Tools", "Connection"], selection: $group)
                TronSettingsDivider()
                TronSettingsRow(icon: "key", title: "Key") {
                    TextField("Any key", text: $key).multilineTextAlignment(.trailing).textInputAutocapitalization(.never)
                }
                TronSettingsDivider()
                filter("Time", icon: "calendar", choices: ["Any time", "Today", "Last 7 days", "Last 30 days"], selection: $time)
                TronSettingsDivider()
                TronSettingsRow(icon: "circle", title: "Status") { Text("Any status").foregroundStyle(Color.tronTextSecondary) }
            }
        }
    }

    private func filter(_ title: String, icon: String, choices: [String], selection: Binding<String>) -> some View {
        TronChoiceRow(icon: icon, title: title, choices: choices.map { TronChoice(id: $0, label: $0) }, selected: selection.wrappedValue) { selection.wrappedValue = $0 }
    }
}
#endif

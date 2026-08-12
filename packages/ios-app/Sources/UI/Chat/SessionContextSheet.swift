import SwiftUI

struct SessionContextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showRaw = false
    @State private var showRename = false
    @State private var showFork = false
    @State private var showTree = false
    @State private var showTerminal = false
    @State private var name = ""
    @State private var compacting = false
    @State private var exportedURL: URL?
    @State private var exporting = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let snapshot = model.selectedSnapshot {
                        contextUsageCard(snapshot)
                        configurationSection(snapshot)
                        navigationSection(snapshot)
                        maintenanceSection(snapshot)
                        exportSection
                        if !snapshot.diagnostics.isEmpty {
                            TronSettingsGroup("Diagnostics", accent: .tronAmber) {
                                VStack(spacing: 0) {
                                    ForEach(Array(snapshot.diagnostics.enumerated()), id: \.offset) { index, diagnostic in
                                        if index > 0 { TronSettingsDivider(accent: .tronAmber) }
                                        TronSettingsRow(
                                            icon: "exclamationmark.triangle",
                                            title: diagnostic.message,
                                            subtitle: diagnostic.type,
                                            accent: .tronAmber
                                        )
                                    }
                                }
                            }
                        }
                    } else {
                        TronLoadingState(label: "Loading session…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Manage Session", accent: .tronEmerald) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task {
                if let id = model.selectedSessionID { try? await model.openSession(id) }
                await model.loadContext()
                await model.loadResources()
            }
            .sheet(isPresented: $showRaw) { runtimeContextSheet }
            .sheet(isPresented: $showFork) { ForkSheet() }
            .sheet(isPresented: $showTree) { SessionTreeSheet() }
            .sheet(isPresented: $showTerminal) { TerminalSheet() }
            .alert("Rename Session", isPresented: $showRename) {
                TextField("Name", text: $name)
                Button("Save") { Task { try? await model.rename(name) } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }

    private func contextUsageCard(_ snapshot: SessionSnapshot) -> some View {
        let percent = snapshot.contextUsage?.percent ?? 0
        let contextWindow = snapshot.contextUsage?.contextWindow ?? 0
        let used = snapshot.contextUsage?.tokens ?? snapshot.stats.tokens.total
        let remaining = max(0, contextWindow - used)
        return VStack(alignment: .leading, spacing: 16) {
            (dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(spacing: 14))) {
                ZStack {
                    Circle().stroke(Color.tronEmerald.opacity(0.16), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: min(max(percent / 100, 0), 1))
                        .stroke(Color.tronEmerald, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(percent.rounded()))%")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                }
                .frame(width: 70, height: 70)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(remaining.formatted(.number.notation(.compactName))) tokens left")
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(used.formatted(.number.notation(.compactName))) used · \(contextWindow.formatted(.number.notation(.compactName))) window")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context usage: \(Int(percent.rounded())) percent used, \(remaining.formatted(.number.notation(.compactName))) tokens left, \(used.formatted(.number.notation(.compactName))) used of a \(contextWindow.formatted(.number.notation(.compactName))) token window")

            Divider().overlay(Color.tronEmerald.opacity(0.14))

            metrics(snapshot)

            Divider().overlay(Color.tronEmerald.opacity(0.14))

            HStack {
                Label("Automatic compaction", systemImage: "arrow.triangle.2.circlepath")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityHidden(true)
                Spacer()
                Button(compacting ? "Compacting…" : "Compact Now") {
                    compacting = true
                    Task { defer { compacting = false }; try? await model.compact() }
                }
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(compacting || snapshot.phase.isActive)
                .accessibilityLabel(compacting ? "Compacting session" : "Compact session now; automatic compaction is enabled")
            }
        }
        .padding(16)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func metrics(_ snapshot: SessionSnapshot) -> some View {
        let values = [
            (snapshot.stats.tokens.input.formatted(.number.notation(.compactName)), "Input"),
            ("\(snapshot.stats.toolCalls)", "Tools"),
            (snapshot.stats.tokens.output.formatted(.number.notation(.compactName)), "Output"),
            (snapshot.stats.cost.formatted(.currency(code: "USD")), "Cost"),
        ]
        if dynamicTypeSize.isAccessibilitySize {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { metric(values[0].0, values[0].1); metric(values[1].0, values[1].1) }
                GridRow { metric(values[2].0, values[2].1); metric(values[3].0, values[3].1) }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in metric(value.0, value.1) }
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(Color.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                .foregroundStyle(Color.tronTextPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private func configurationSection(_ snapshot: SessionSnapshot) -> some View {
        TronSettingsGroup("Configuration", accent: .tronPurple) {
            VStack(spacing: 0) {
                Menu {
                    ForEach(model.models.filter(\.available)) { candidate in
                        Button {
                            Task { try? await model.setModel(candidate.ref) }
                        } label: {
                            if snapshot.model == candidate.ref {
                                Label(candidate.name, systemImage: "checkmark")
                            } else {
                                Text(candidate.name)
                            }
                        }
                    }
                } label: {
                    TronSettingsRow(
                        icon: "cpu",
                        title: "Model",
                        subtitle: snapshot.model.map { "\($0.provider) / \($0.id)" } ?? "Not selected",
                        accent: .tronPurple
                    )
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Model: \(snapshot.model.map { "\($0.provider) / \($0.id)" } ?? "Not selected")")
                TronSettingsDivider(accent: .tronPurple)
                Menu {
                    ForEach(snapshot.availableThinkingLevels, id: \.self) { level in
                        Button {
                            Task { try? await model.setThinking(level) }
                        } label: {
                            if snapshot.thinkingLevel == level { Label(level.capitalized, systemImage: "checkmark") }
                            else { Text(level.capitalized) }
                        }
                    }
                } label: {
                    TronSettingsRow(
                        icon: "brain",
                        title: "Thinking",
                        subtitle: "Reasoning effort for this session",
                        accent: .tronPurple
                    ) {
                        Text(snapshot.thinkingLevel.capitalized)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                    }
                    .accessibilityHidden(true)
                }
                .accessibilityLabel("Thinking: \(snapshot.thinkingLevel.capitalized). Reasoning effort for this session")
                TronSettingsDivider(accent: .tronPurple)
                Button {
                    name = snapshot.name ?? ""
                    showRename = true
                } label: {
                    TronSettingsRow(icon: "pencil", title: "Rename Session", accent: .tronPurple)
                    .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename Session")
            }
        }
    }

    private func navigationSection(_ snapshot: SessionSnapshot) -> some View {
        TronSettingsGroup("Session", detail: snapshot.cwd, accent: .tronCyan) {
            VStack(spacing: 0) {
                manageRow(icon: "doc.text.magnifyingglass", title: "Agent Context", subtitle: "Instructions, conversation, attachments, and available tools", accent: .tronPurple) { showRaw = true }
                TronSettingsDivider(accent: .tronCyan)
                manageRow(icon: "point.3.connected.trianglepath.dotted", title: "Session History", subtitle: "Navigate, label, or continue from an earlier entry", accent: .tronCyan) { showTree = true }
                TronSettingsDivider(accent: .tronCyan)
                manageRow(icon: "arrow.triangle.branch", title: "Fork Session", subtitle: "Create a canonical branch from a user message", accent: .tronTeal) { showFork = true }
                TronSettingsDivider(accent: .tronCyan)
                manageRow(icon: "terminal", title: "Terminal", subtitle: "Open or reattach the retained Mac terminal", accent: .tronEmerald) { showTerminal = true }
            }
        }
    }

    private func maintenanceSection(_ snapshot: SessionSnapshot) -> some View {
        TronSettingsGroup("Runtime", accent: .tronAmber) {
            VStack(spacing: 0) {
                manageRow(icon: "arrow.clockwise", title: "Reload Resources", subtitle: "Reload extensions, skills, prompts, and project resources", accent: .tronAmber) {
                    Task {
                        try? await model.reloadResources()
                        await model.loadContext()
                        await model.loadResources()
                    }
                }
                TronSettingsDivider(accent: .tronAmber)
                TronSettingsRow(
                    icon: "waveform.path.ecg",
                    title: "Phase",
                    subtitle: "\(snapshot.stats.totalMessages) messages · \(snapshot.stats.toolCalls) tool calls",
                    accent: .tronAmber
                ) {
                    Text(snapshot.phase.rawValue.capitalized)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                }
            }
        }
    }

    private var exportSection: some View {
        TronSettingsGroup("Export and Share", accent: .tronBlue) {
            VStack(spacing: 0) {
                manageRow(icon: "doc.richtext", title: exporting ? "Exporting…" : "HTML Export", accent: .tronBlue) { prepareExport("html") }
                TronSettingsDivider(accent: .tronBlue)
                manageRow(icon: "doc.text", title: exporting ? "Exporting…" : "JSONL Export", accent: .tronBlue) { prepareExport("jsonl") }
                if let exportedURL {
                    TronSettingsDivider(accent: .tronBlue)
                    ShareLink(item: exportedURL) {
                        TronSettingsRow(icon: "square.and.arrow.up", title: "Share \(exportedURL.lastPathComponent)", accent: .tronBlue)
                    }
                }
            }
        }
    }

    private func manageRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var runtimeContextSheet: some View {
        NavigationStack {
            ScrollView {
                TronStructuredJSONView(value: model.context ?? .null, title: "Runtime Context", accent: .tronPurple)
                    .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Runtime Context", accent: .tronPurple) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showRaw = false } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }

    private func prepareExport(_ format: String) {
        exporting = true
        Task {
            defer { exporting = false }
            do { exportedURL = try await model.exportSession(format: format) }
            catch { model.lastError = error.localizedDescription }
        }
    }
}

struct ForkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var position = "before"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TronSegmentedControl(
                        options: [("Fork and edit prompt", "before"), ("Clone after prompt", "at")],
                        selection: $position
                    )
                    TronCaption(position == "before"
                        ? "Creates a new session before the selected message and restores that prompt to the composer for editing."
                        : "Creates a new session containing the selected message and everything before it.")

                    TronSettingsGroup("Choose a message", accent: .tronTeal) {
                        VStack(spacing: 0) {
                            ForEach(Array((model.selectedSnapshot?.transcript.filter { $0.role == .user } ?? []).enumerated()), id: \.element.id) { index, item in
                                if index > 0 { TronSettingsDivider(accent: .tronTeal) }
                                Button {
                                    Task {
                                        do {
                                            _ = try await model.fork(entryID: item.id, position: position)
                                            dismiss()
                                        } catch { model.lastError = error.localizedDescription }
                                    }
                                } label: {
                                    TronSettingsRow(
                                        icon: "bubble.left",
                                        title: item.text,
                                        subtitle: item.timestamp,
                                        accent: .tronTeal
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: position == "before" ? "Fork Session" : "Clone Session") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task { await model.loadTree() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

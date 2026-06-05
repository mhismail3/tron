import SwiftUI

@available(iOS 26.0, *)
struct WorkDashboardView: View {
    let engineClient: EngineClient
    let actions: DashboardToolbarActions
    let selectedSessionId: String?

    @State private var state: WorkDashboardState
    @State private var selectedWorker: WorkWorkerDTO?
    @State private var showAuditDetails = false

    init(
        engineClient: EngineClient,
        actions: DashboardToolbarActions,
        selectedSessionId: String? = nil
    ) {
        self.engineClient = engineClient
        self.actions = actions
        self.selectedSessionId = selectedSessionId
        _state = State(initialValue: WorkDashboardState(engineClient: engineClient))
    }

    var body: some View {
        WorkDashboardContent(
            snapshot: state.snapshot,
            loadState: state.loadState,
            onSelectWorker: { selectedWorker = $0 },
            onAudit: { showAuditDetails = true }
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            DashboardToolbarContent(title: "Work", accent: .tronEmerald, actions: actions)
        }
        .task(id: selectedSessionId) {
            await state.refresh(sessionId: selectedSessionId)
        }
        .refreshable {
            await state.refresh(sessionId: selectedSessionId)
        }
        .sheet(item: $selectedWorker) { worker in
            WorkWorkerDetailSheet(
                worker: worker,
                milestones: state.recentMilestonesForWorker(worker),
                guardrails: state.guardrailsForWorker(worker)
            )
        }
        .sheet(isPresented: $showAuditDetails) {
            NavigationStack {
                EngineConsoleView(
                    engineClient: engineClient,
                    actions: actions,
                    eventDatabaseStorageMode: .primaryDocuments
                )
            }
        }
    }
}

@available(iOS 26.0, *)
struct WorkDashboardContent: View {
    let snapshot: WorkSnapshotDTO?
    let loadState: WorkDashboardState.LoadState
    let onSelectWorker: (WorkWorkerDTO) -> Void
    let onAudit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let snapshot {
                    WorkAutonomyPanel(autonomy: snapshot.autonomy)
                    WorkActivePanel(activeWork: snapshot.activeWork)
                    WorkWorkersPanel(workers: snapshot.workers, onSelectWorker: onSelectWorker)
                    WorkGuardrailsPanel(guardrails: snapshot.guardrails)
                    WorkMilestonesPanel(milestones: snapshot.recentMilestones)
                    WorkAuditPanel(auditRefs: snapshot.auditRefs, onAudit: onAudit)
                } else if case .failed(let message) = loadState {
                    WorkErrorPanel(message: message)
                } else {
                    WorkLoadingPanel()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .tronScreenBackground()
    }
}

@available(iOS 26.0, *)
private struct WorkAutonomyPanel: View {
    let autonomy: WorkAutonomyDTO

    var body: some View {
        WorkPanel {
            HStack(alignment: .top, spacing: 12) {
                WorkSymbol("bolt.shield", tint: autonomy.interactiveApprovalPrompts ? .tronAmber : .tronEmerald)

                VStack(alignment: .leading, spacing: 6) {
                    Text(autonomy.statusLabel)
                        .font(TronTypography.sans(size: 22, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(autonomy.summary)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct WorkActivePanel: View {
    let activeWork: [WorkActiveItemDTO]

    var body: some View {
        WorkSection(title: "Active Work", systemImage: "hourglass.circle") {
            if activeWork.isEmpty {
                WorkEmptyLine(text: "No waiting work")
            } else {
                VStack(spacing: 8) {
                    ForEach(activeWork) { item in
                        WorkStatusRow(
                            title: workTitle(item.functionId),
                            subtitle: item.status.capitalized,
                            tint: .tronAmber,
                            systemImage: "hourglass"
                        )
                    }
                }
            }
        }
    }

    private func workTitle(_ functionId: String?) -> String {
        functionId?.replacingOccurrences(of: "::", with: " ") ?? "Work item"
    }
}

@available(iOS 26.0, *)
private struct WorkWorkersPanel: View {
    let workers: [WorkWorkerDTO]
    let onSelectWorker: (WorkWorkerDTO) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 10)]
    }

    var body: some View {
        WorkSection(title: "Workers", systemImage: "person.2") {
            if workers.isEmpty {
                WorkEmptyLine(text: "No active workers")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(workers) { worker in
                        Button {
                            onSelectWorker(worker)
                        } label: {
                            WorkWorkerCard(worker: worker)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(worker.label), \(worker.health)")
                        .hoverEffect(.highlight)
                    }
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct WorkWorkerCard: View {
    let worker: WorkWorkerDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                WorkSymbol(worker.workerType == "agent" ? "person.crop.circle" : "hammer", tint: worker.health.workTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(worker.label)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(worker.status)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                WorkPill(text: worker.health.capitalized, tint: worker.health.workTint)
                WorkPill(text: "\(worker.abilityCount) abilities", tint: .tronInfo)
            }
        }
        .padding(12)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        }
    }
}

@available(iOS 26.0, *)
private struct WorkGuardrailsPanel: View {
    let guardrails: [WorkGuardrailDTO]

    var body: some View {
        WorkSection(title: "Guardrails", systemImage: "shield") {
            if guardrails.isEmpty {
                WorkStatusRow(
                    title: "Clear",
                    subtitle: "Work can continue unless a server guardrail blocks it.",
                    tint: .tronEmerald,
                    systemImage: "checkmark.circle"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(guardrails) { guardrail in
                        WorkStatusRow(
                            title: guardrail.risk.map { "\($0) guardrail" } ?? "Guardrail",
                            subtitle: guardrail.summary ?? guardrail.status.capitalized,
                            tint: .tronAmber,
                            systemImage: "exclamationmark.shield"
                        )
                    }
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct WorkMilestonesPanel: View {
    let milestones: [WorkMilestoneDTO]

    var body: some View {
        WorkSection(title: "Recent Results", systemImage: "checkmark.circle") {
            if milestones.isEmpty {
                WorkEmptyLine(text: "No recent results")
            } else {
                VStack(spacing: 8) {
                    ForEach(milestones.prefix(6)) { milestone in
                        WorkStatusRow(
                            title: milestone.functionId?.replacingOccurrences(of: "::", with: " ") ?? "Result",
                            subtitle: milestone.status.capitalized,
                            tint: milestone.status == "completed" ? .tronEmerald : .tronError,
                            systemImage: milestone.status == "completed" ? "checkmark.circle" : "xmark.octagon"
                        )
                    }
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct WorkAuditPanel: View {
    let auditRefs: [WorkAuditRefDTO]
    let onAudit: () -> Void

    var body: some View {
        WorkPanel {
            HStack(spacing: 12) {
                WorkSymbol("list.bullet.rectangle", tint: .tronSlate)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audit")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(auditRefs.count) refs available")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                Button(action: onAudit) {
                    Label("Audit Details", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tronEmerald)
            }
        }
    }
}

@available(iOS 26.0, *)
struct WorkWorkerDetailSheet: View {
    let worker: WorkWorkerDTO
    let milestones: [WorkMilestoneDTO]
    let guardrails: [WorkGuardrailDTO]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WorkPanel {
                        HStack(alignment: .top, spacing: 12) {
                            WorkSymbol(worker.workerType == "agent" ? "person.crop.circle" : "hammer", tint: worker.health.workTint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(worker.label)
                                    .font(TronTypography.sans(size: 24, weight: .semibold))
                                    .foregroundStyle(.tronTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(worker.status)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronTextSecondary)
                            }
                        }
                    }

                    WorkSection(title: "Health", systemImage: "heart.text.square") {
                        VStack(spacing: 8) {
                            WorkStatusRow(
                                title: worker.health.capitalized,
                                subtitle: healthSubtitle,
                                tint: worker.health.workTint,
                                systemImage: healthSystemImage
                            )
                        }
                    }

                    WorkSection(title: "Trust", systemImage: "checkmark.seal") {
                        WorkStatusRow(
                            title: worker.trust,
                            subtitle: trustSubtitle,
                            tint: worker.health.workTint,
                            systemImage: "checkmark.seal"
                        )
                    }

                    WorkSection(title: "Generated Controls", systemImage: "slider.horizontal.3") {
                        if worker.generatedControls.isEmpty {
                            WorkEmptyLine(text: "No controls for this worker")
                        } else {
                            VStack(spacing: 8) {
                                ForEach(worker.generatedControls) { control in
                                    WorkStatusRow(
                                        title: control.label,
                                        subtitle: controlSubtitle(control),
                                        tint: control.status.workTint,
                                        systemImage: controlSystemImage(control)
                                    )
                                }
                            }
                        }
                    }

                    WorkSection(title: "Guardrails", systemImage: "shield") {
                        if guardrails.isEmpty {
                            WorkStatusRow(
                                title: "Clear",
                                subtitle: "No guardrail is blocking this worker.",
                                tint: .tronEmerald,
                                systemImage: "checkmark.circle"
                            )
                        } else {
                            VStack(spacing: 8) {
                                ForEach(guardrails) { guardrail in
                                    WorkStatusRow(
                                        title: guardrail.risk.map { "\($0) guardrail" } ?? "Guardrail",
                                        subtitle: guardrail.summary ?? guardrail.status.capitalized,
                                        tint: .tronAmber,
                                        systemImage: "exclamationmark.shield"
                                    )
                                }
                            }
                        }
                    }

                    WorkSection(title: "Abilities", systemImage: "wand.and.sparkles") {
                        VStack(spacing: 8) {
                            ForEach(worker.abilities) { ability in
                                WorkStatusRow(
                                    title: ability.label,
                                    subtitle: "\(ability.risk) risk - \(ability.health)",
                                    tint: ability.health.workTint,
                                    systemImage: "sparkle"
                                )
                            }
                        }
                    }

                    WorkSection(title: "Recent Work", systemImage: "clock") {
                        if milestones.isEmpty {
                            WorkEmptyLine(text: "No recent work for this worker")
                        } else {
                            VStack(spacing: 8) {
                                ForEach(milestones) { milestone in
                                    WorkStatusRow(
                                        title: milestone.functionId?.replacingOccurrences(of: "::", with: " ") ?? "Result",
                                        subtitle: milestone.status.capitalized,
                                        tint: milestone.status == "completed" ? .tronEmerald : .tronError,
                                        systemImage: milestone.status == "completed" ? "checkmark.circle" : "xmark.octagon"
                                    )
                                }
                            }
                        }
                    }

                    if let auditRef = worker.auditRef {
                        WorkSection(title: "Audit History", systemImage: "list.bullet.rectangle") {
                            WorkStatusRow(
                                title: auditRef.kind.capitalized,
                                subtitle: auditRef.id ?? "Catalog \(auditRef.catalogRevision.map(String.init) ?? "current")",
                                tint: .tronSlate,
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }
                    }
                }
                .padding(18)
            }
            .tronScreenBackground()
            .navigationTitle("Worker")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var healthSubtitle: String {
        if let elapsedMs = worker.elapsedMs {
            return "\(worker.status) - \(formatElapsed(elapsedMs))"
        }
        return worker.status
    }

    private var healthSystemImage: String {
        switch worker.health.lowercased() {
        case "healthy":
            return "checkmark.circle"
        case "degraded", "unknown":
            return "exclamationmark.triangle"
        case "unhealthy", "failed":
            return "xmark.octagon"
        default:
            return "circle"
        }
    }

    private var trustSubtitle: String {
        if worker.namespaceClaims.isEmpty {
            return "No namespace claims"
        }
        return worker.namespaceClaims.joined(separator: ", ")
    }

    private func controlSubtitle(_ control: WorkGeneratedControlDTO) -> String {
        [control.kind, control.status, control.functionId]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " - ")
    }

    private func controlSystemImage(_ control: WorkGeneratedControlDTO) -> String {
        switch control.kind.lowercased() {
        case "read":
            return "doc.text.magnifyingglass"
        case "detail":
            return "sidebar.right"
        case "guarded run":
            return "exclamationmark.shield"
        case "record":
            return "list.bullet.rectangle"
        default:
            return "play.circle"
        }
    }

    private func formatElapsed(_ elapsedMs: UInt64) -> String {
        if elapsedMs < 1000 {
            return "\(elapsedMs) ms"
        }
        let seconds = Double(elapsedMs) / 1000.0
        return "\(String(format: "%.1f", seconds)) s"
    }
}

@available(iOS 26.0, *)
private struct WorkSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 24)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
            }
            content()
        }
    }
}

@available(iOS 26.0, *)
private struct WorkPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.tronBorder, lineWidth: 0.5)
            }
    }
}

@available(iOS 26.0, *)
private struct WorkStatusRow: View {
    let title: String
    let subtitle: String
    let tint: Color
    let systemImage: String

    var body: some View {
        WorkPanel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct WorkEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeBody))
            .foregroundStyle(.tronTextMuted)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 26.0, *)
private struct WorkLoadingPanel: View {
    var body: some View {
        WorkPanel {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Work")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 26.0, *)
private struct WorkErrorPanel: View {
    let message: String

    var body: some View {
        WorkPanel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.tronError)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct WorkSymbol: View {
    let name: String
    let tint: Color

    init(_ name: String, tint: Color) {
        self.name = name
        self.tint = tint
    }

    var body: some View {
        Image(systemName: name)
            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@available(iOS 26.0, *)
private struct WorkPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private extension String {
    var workTint: Color {
        switch lowercased() {
        case "healthy":
            return .tronEmerald
        case "degraded", "unknown":
            return .tronAmber
        case "unhealthy", "failed":
            return .tronError
        default:
            return .tronInfo
        }
    }
}

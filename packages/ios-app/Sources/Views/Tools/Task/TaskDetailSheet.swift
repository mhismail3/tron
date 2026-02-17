import SwiftUI

/// Sheet view for task manager chip taps — renders structured content for every action type.
///
/// Content routing:
///   - Entity actions (create/update/get/delete/log_time + variants) → EntitySnapshotCard
///   - List actions (list, list_projects, list_areas, search) → Structured list view
///   - Delete confirmations → Simple confirmation card
///   - Running state → Waiting spinner
@available(iOS 26.0, *)
struct TaskDetailSheet: View {
    let chipData: TaskManagerChipData

    @Environment(\.dismiss) private var dismiss

    private let accentColor: Color = .tronSlate

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    actionHeaderSection(chipData)
                    contentSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 14))
                            .foregroundStyle(accentColor)
                        Text("Task Manager")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accentColor)
    }

    // MARK: - Content Routing

    @ViewBuilder
    private var contentSection: some View {
        if let entity = chipData.entityDetail {
            // Entity actions: create, update, get, delete, log_time (+ project/area variants)
            EntitySnapshotCard(entity: entity, action: chipData.action)
        } else if let listResult = chipData.listResult {
            // List/search actions
            listResultSection(listResult)
        } else if chipData.status == .running {
            waitingSection
        } else if let result = chipData.fullResult, !result.isEmpty {
            // Fallback: raw text for any unhandled format
            rawResultSection(result)
        } else {
            waitingSection
        }
    }

    // MARK: - Action Header

    @ViewBuilder
    private func actionHeaderSection(_ chip: TaskManagerChipData) -> some View {
        HStack(spacing: 8) {
            Text(chip.action.replacingOccurrences(of: "_", with: " "))
                .font(TronTypography.mono(size: 11, weight: .medium))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.15))
                .clipShape(Capsule())

            if let title = chip.taskTitle {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - List Result Rendering

    @ViewBuilder
    private func listResultSection(_ result: ListResult) -> some View {
        switch result {
        case .tasks(let items):
            taskListSection(items)
        case .searchResults(let items):
            searchResultsSection(items)
        case .projects(let items):
            projectListSection(items)
        case .areas(let items):
            areaListSection(items)
        case .empty(let message):
            emptyResultSection(message)
        }
    }

    // MARK: - Task List

    @ViewBuilder
    private func taskListSection(_ items: [TaskListItem]) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tronTextMuted)
                    Text("Tasks")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    countPill(items.count)
                    Spacer()
                }

                ForEach(items) { item in
                    taskListRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func taskListRow(_ item: TaskListItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot(for: item.mark)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(item.mark == "x" ? .tronTextMuted : .tronTextPrimary)
                        .strikethrough(item.mark == "x", color: .tronTextMuted)
                        .lineLimit(2)

                    if let priority = item.priority {
                        Text(priority)
                            .font(TronTypography.mono(size: 10, weight: .medium))
                            .foregroundStyle(priorityColor(priority))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(priorityColor(priority).opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(item.taskId)
                        .font(TronTypography.mono(size: 10, weight: .regular))
                        .foregroundStyle(.tronTextMuted.opacity(0.6))

                    if let due = item.dueDate {
                        HStack(spacing: 3) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9))
                            Text(due)
                        }
                        .font(TronTypography.mono(size: 10, weight: .regular))
                        .foregroundStyle(.tronWarning)
                    }
                }
            }

            Spacer()
        }
        .padding(.leading, 4)
    }

    // MARK: - Search Results

    @ViewBuilder
    private func searchResultsSection(_ items: [SearchResultItem]) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tronTextMuted)
                    Text("Search Results")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    countPill(items.count)
                    Spacer()
                }

                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        statusDot(for: statusMark(item.status))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                                .foregroundStyle(item.status == "completed" ? .tronTextMuted : .tronTextPrimary)
                                .strikethrough(item.status == "completed", color: .tronTextMuted)
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                Text(item.itemId)
                                    .font(TronTypography.mono(size: 10, weight: .regular))
                                    .foregroundStyle(.tronTextMuted.opacity(0.6))

                                statusPill(item.status)
                            }
                        }

                        Spacer()
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - Project List

    @ViewBuilder
    private func projectListSection(_ items: [ProjectListItem]) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.tronTextMuted)
                    Text("Projects")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    countPill(items.count)
                    Spacer()
                }

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                                .foregroundStyle(.tronTextPrimary)
                                .lineLimit(2)

                            statusPill(item.status)

                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text(item.projectId)
                                .font(TronTypography.mono(size: 10, weight: .regular))
                                .foregroundStyle(.tronTextMuted.opacity(0.6))

                            if let completed = item.completedTasks, let total = item.totalTasks, total > 0 {
                                progressIndicator(completed: completed, total: total)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Area List

    @ViewBuilder
    private func areaListSection(_ items: [AreaListItem]) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(.tronTextMuted)
                    Text("Areas")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    countPill(items.count)
                    Spacer()
                }

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                                .foregroundStyle(.tronTextPrimary)
                                .lineLimit(2)

                            statusPill(item.status)

                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text(item.areaId)
                                .font(TronTypography.mono(size: 10, weight: .regular))
                                .foregroundStyle(.tronTextMuted.opacity(0.6))

                            if let pc = item.projectCount {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 9))
                                    Text("\(pc) project\(pc == 1 ? "" : "s")")
                                }
                                .font(TronTypography.mono(size: 10, weight: .regular))
                                .foregroundStyle(.tronTextMuted)
                            }

                            if let tc = item.taskCount, let ac = item.activeTaskCount {
                                HStack(spacing: 3) {
                                    Image(systemName: "checklist")
                                        .font(.system(size: 9))
                                    Text("\(tc) task\(tc == 1 ? "" : "s") (\(ac) active)")
                                }
                                .font(TronTypography.mono(size: 10, weight: .regular))
                                .foregroundStyle(.tronTextMuted)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private func emptyResultSection(_ message: String) -> some View {
        glassCard {
            HStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 18))
                    .foregroundStyle(.tronTextMuted.opacity(0.5))
                Text(message)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Raw Result Fallback

    @ViewBuilder
    private func rawResultSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronTextMuted)
                Text("Result")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }

            Text(result)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tronSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.tronBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Waiting State

    @ViewBuilder
    private var waitingSection: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(.tronAmber)
            Text("Waiting for result...")
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Shared Components

    @ViewBuilder
    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(accentColor.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
    }

    @ViewBuilder
    private func countPill(_ count: Int) -> some View {
        Text("\(count)")
            .font(TronTypography.mono(size: 11, weight: .medium))
            .foregroundStyle(.tronTextMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accentColor.opacity(0.15))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func statusPill(_ status: String) -> some View {
        let color = statusColor(status)
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(status.replacingOccurrences(of: "_", with: " "))
                .font(TronTypography.mono(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func progressIndicator(completed: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            // Mini progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.tronBorder.opacity(0.3))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(completed == total ? Color.tronSuccess : accentColor)
                        .frame(width: geometry.size.width * CGFloat(completed) / CGFloat(max(total, 1)))
                }
            }
            .frame(width: 40, height: 4)

            Text("\(completed)/\(total)")
                .font(TronTypography.mono(size: 10, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
    }

    @ViewBuilder
    private func statusDot(for mark: String) -> some View {
        let color: Color = switch mark {
        case "x": .tronSuccess
        case ">": .tronTeal
        case "b": .tronSlate
        case "-": .tronError
        default: .tronSlate.opacity(0.5)
        }
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .padding(.top, 5)
    }

    // MARK: - Color Helpers

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .tronSuccess
        case "in_progress": return .tronTeal
        case "cancelled": return .tronError
        case "backlog": return .tronSlate
        case "paused": return .tronAmber
        case "archived": return .tronSlate
        case "active": return .tronTeal
        case "pending": return .tronSlate
        default: return .tronSlate
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "critical": return .tronError
        case "high": return .orange
        case "low": return .tronTextMuted
        default: return .tronTextSecondary
        }
    }

    private func statusMark(_ status: String) -> String {
        switch status {
        case "completed": return "x"
        case "in_progress": return ">"
        case "cancelled": return "-"
        case "backlog": return "b"
        default: return " "
        }
    }
}

// MARK: - Legacy Fallback

struct TaskDetailSheetLegacy: View {
    let rpcClient: RPCClient
    @Bindable var taskState: TaskState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if taskState.isLoading {
                    ProgressView()
                        .tint(.green)
                } else if taskState.tasks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checklist")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("No Tasks")
                            .font(.headline)
                            .foregroundStyle(.tronTextPrimary)
                    }
                } else {
                    List {
                        ForEach(taskState.tasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.status == .inProgress ? (task.activeForm ?? task.title) : task.title)
                                    .font(.body)
                                    .foregroundStyle(task.status == .completed ? .gray : .tronTextPrimary)
                                HStack {
                                    Text(task.source.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                    Text(task.status.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            }
                            .listRowBackground(Color.gray.opacity(0.2))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadTasks()
            }
        }
    }

    private func loadTasks() async {
        taskState.startLoading()
        do {
            let result = try await rpcClient.misc.listTasks()
            taskState.updateTasks(result.tasks)
        } catch {
            taskState.setError(error.localizedDescription)
        }
    }
}

import SwiftUI

/// Sheet view for task manager toolbar button — shows live task list from DB.
/// Separated from TaskDetailSheet which shows entity snapshots from chip taps.
@available(iOS 26.0, *)
struct TaskListSheet: View {
    let rpcClient: RPCClient
    @Bindable var taskState: TaskState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    tasksOverviewSection
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
                            .foregroundStyle(.tronSlate)
                        Text("Task Manager")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronSlate)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronSlate)
                }
            }
            .task {
                await loadTasks()
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronSlate)
    }

    // MARK: - Tasks Overview Section

    @ViewBuilder
    private var tasksOverviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronTextMuted)
                Text("Tasks")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)

                if !taskState.tasks.isEmpty {
                    Text("\(taskState.tasks.count)")
                        .font(TronTypography.mono(size: 11, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tronSlate.opacity(0.4))
                        .clipShape(Capsule())
                }

                Spacer()
            }

            if taskState.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.tronSlate)
                    Text("Loading tasks...")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tronSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let error = taskState.errorMessage {
                VStack(spacing: 8) {
                    Text(error)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(.tronError)
                    Button("Retry") {
                        Task { await loadTasks() }
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronSlate)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tronSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if taskState.tasks.isEmpty {
                emptyTasksView
            } else {
                taskListContent
            }
        }
    }

    @ViewBuilder
    private var taskListContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !taskState.inProgressTasks.isEmpty {
                taskGroup(title: "In Progress", icon: "circle.fill", iconColor: .tronSlate, tasks: taskState.inProgressTasks)
            }
            if !taskState.pendingTasks.isEmpty {
                taskGroup(title: "Pending", icon: "circle", iconColor: .tronSlate, tasks: taskState.pendingTasks)
            }
            if !taskState.backlogTasks.isEmpty {
                taskGroup(title: "Backlog", icon: "tray", iconColor: .tronSlate, tasks: taskState.backlogTasks)
            }
            if !taskState.completedTasks.isEmpty {
                taskGroup(title: "Completed", icon: "checkmark.circle.fill", iconColor: .tronTextMuted, tasks: taskState.completedTasks)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tronBorder.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func taskGroup(title: String, icon: String, iconColor: Color, tasks: [RpcTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(TronTypography.mono(size: 11, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text("\(tasks.count)")
                    .font(TronTypography.mono(size: 10, weight: .medium))
                    .foregroundStyle(.tronTextMuted.opacity(0.7))
            }

            ForEach(tasks) { task in
                taskRow(task)
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: RpcTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(task.status == .inProgress ? (task.activeForm ?? task.title) : task.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(task.status == .completed ? .tronTextMuted : .tronTextPrimary)
                    .strikethrough(task.status == .completed, color: .tronTextMuted)
                    .lineLimit(2)

                if task.priority == .high || task.priority == .critical {
                    Text(task.priority.displayName)
                        .font(TronTypography.mono(size: 10, weight: .medium))
                        .foregroundStyle(task.priority == .critical ? .tronError : .orange)
                }
            }

            Spacer(minLength: 8)

            Text(task.formattedCreatedAt)
                .font(TronTypography.mono(size: 10, weight: .regular))
                .foregroundStyle(.tronTextMuted.opacity(0.7))
        }
        .padding(.vertical, 3)
        .padding(.leading, 16)
    }

    @ViewBuilder
    private var emptyTasksView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 14))
                .foregroundStyle(.tronTextMuted)
            Text("No tasks")
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Data Loading

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

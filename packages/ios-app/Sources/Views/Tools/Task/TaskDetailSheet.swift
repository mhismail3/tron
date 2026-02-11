import SwiftUI

/// Sheet view displaying persistent tasks
@available(iOS 26.0, *)
struct TaskDetailSheet: View {
    let rpcClient: RPCClient
    @Bindable var taskState: TaskState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if taskState.isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else if let error = taskState.errorMessage {
                    errorView(error)
                } else if taskState.tasks.isEmpty {
                    emptyStateView
                } else {
                    contentView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Tasks")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                }
            }
            .task {
                await loadTasks()
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // In Progress Section
                if !taskState.inProgressTasks.isEmpty {
                    taskSection(
                        title: "In Progress",
                        icon: "circle.fill",
                        iconColor: .tronEmerald,
                        tasks: taskState.inProgressTasks
                    )
                }

                // Pending Section
                if !taskState.pendingTasks.isEmpty {
                    taskSection(
                        title: "Pending",
                        icon: "circle",
                        iconColor: .tronSlate,
                        tasks: taskState.pendingTasks
                    )
                }

                // Backlog Section (collapsed by default)
                if !taskState.backlogTasks.isEmpty {
                    taskSection(
                        title: "Backlog",
                        icon: "tray",
                        iconColor: .tronSlate,
                        tasks: taskState.backlogTasks
                    )
                }

                // Completed Section
                if !taskState.completedTasks.isEmpty {
                    taskSection(
                        title: "Completed",
                        icon: "checkmark.circle.fill",
                        iconColor: .tronTextMuted,
                        tasks: taskState.completedTasks
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func taskSection(
        title: String,
        icon: String,
        iconColor: Color,
        tasks: [RpcTask]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text("\(tasks.count)")
                    .font(TronTypography.mono(size: 11, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tronSlate.opacity(0.4))
                    .clipShape(Capsule())
                Spacer()
            }

            // Task Items
            ForEach(tasks) { task in
                taskRow(task)
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: RpcTask) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                // Show activeForm for in-progress, title otherwise
                Text(task.status == .inProgress ? (task.activeForm ?? task.title) : task.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                    .foregroundStyle(task.status == .completed ? .tronTextMuted : .tronTextPrimary)
                    .strikethrough(task.status == .completed, color: .tronTextMuted)

                // Priority badge for high/critical
                if task.priority == .high || task.priority == .critical {
                    Text(task.priority.displayName)
                        .font(TronTypography.mono(size: 10, weight: .medium))
                        .foregroundStyle(task.priority == .critical ? .tronError : .orange)
                }
            }

            Spacer(minLength: 16)

            // Timestamp - right aligned
            Text(task.formattedCreatedAt)
                .font(TronTypography.mono(size: 11, weight: .regular))
                .foregroundStyle(.tronTextMuted.opacity(0.7))
        }
        .padding(.vertical, 6)
        .padding(.leading, 20)
    }

    // MARK: - Empty/Error States

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.tronTextMuted)
            Text("No Tasks")
                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
            Text("Tasks will appear here when the agent creates them")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.tronError)
            Text("Failed to Load")
                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task {
                    await loadTasks()
                }
            }
            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            .foregroundStyle(.tronEmerald)
            .padding(.top, 8)
        }
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

// MARK: - Legacy Fallback

/// Fallback view for iOS versions before 26.0
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

import SwiftUI

/// Sheet view displaying tasks for the current session
/// Similar to ContextAuditView in style and behavior
@available(iOS 26.0, *)
struct TodoDetailSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let workspaceId: String?
    @Bindable var todoState: TodoState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if todoState.isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else if let error = todoState.errorMessage {
                    errorView(error)
                } else if todoState.todos.isEmpty && todoState.backlogTasks.isEmpty {
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
                await loadTodos()
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
                if !todoState.inProgressTodos.isEmpty {
                    todoSection(
                        title: "In Progress",
                        icon: "circle.fill",
                        iconColor: .tronEmerald,
                        todos: todoState.inProgressTodos
                    )
                }

                // Pending Section
                if !todoState.pendingTodos.isEmpty {
                    todoSection(
                        title: "Pending",
                        icon: "circle",
                        iconColor: .tronSlate,
                        todos: todoState.pendingTodos
                    )
                }

                // Completed Section
                if !todoState.completedTodos.isEmpty {
                    todoSection(
                        title: "Completed",
                        icon: "checkmark.circle.fill",
                        iconColor: .tronTextMuted,
                        todos: todoState.completedTodos
                    )
                }

                // Backlog Section (expandable)
                if !todoState.displayedBacklogTasks.isEmpty {
                    backlogSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func todoSection(
        title: String,
        icon: String,
        iconColor: Color,
        todos: [RpcTodoItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                Text(title.uppercased())
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                // Count bubble
                Text("\(todos.count)")
                    .font(TronTypography.mono(size: 11, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tronSlate.opacity(0.4))
                    .clipShape(Capsule())
                Spacer()
            }

            // Todo Items
            ForEach(todos) { todo in
                todoRow(todo)
            }
        }
    }

    @ViewBuilder
    private func todoRow(_ todo: RpcTodoItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Main content - show activeForm for in-progress, content otherwise
            Text(todo.status == .inProgress ? todo.activeForm : todo.content)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                .foregroundStyle(todo.status == .completed ? .tronTextMuted : .tronTextPrimary)
                .strikethrough(todo.status == .completed, color: .tronTextMuted)

            Spacer(minLength: 16)

            // Timestamp - right aligned, smaller
            Text(todo.formattedCreatedAt)
                .font(TronTypography.mono(size: 11, weight: .regular))
                .foregroundStyle(.tronTextMuted.opacity(0.7))
        }
        .padding(.vertical, 6)
        .padding(.leading, 20)
    }

    // MARK: - Backlog Section

    @ViewBuilder
    private var backlogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expandable Header
            Button {
                todoState.toggleBacklog()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12))
                        .foregroundStyle(.tronSlate)
                    Text("BACKLOG")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    // Count bubble
                    Text("\(todoState.backlogCount)")
                        .font(TronTypography.mono(size: 11, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tronSlate.opacity(0.4))
                        .clipShape(Capsule())
                    Spacer()
                    Image(systemName: todoState.isBacklogExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            // Expanded Content
            if todoState.isBacklogExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Incomplete tasks from previous sessions")
                        .font(TronTypography.mono(size: 11, weight: .regular))
                        .foregroundStyle(.tronTextMuted.opacity(0.7))
                        .padding(.leading, 20)
                        .padding(.bottom, 2)

                    ForEach(todoState.displayedBacklogTasks) { task in
                        backlogTaskRow(task)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func backlogTaskRow(_ task: RpcBackloggedTask) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(task.content)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                .foregroundStyle(.tronTextPrimary)

            Spacer(minLength: 12)

            // Timestamp
            Text(task.formattedBackloggedAt)
                .font(TronTypography.mono(size: 11, weight: .regular))
                .foregroundStyle(.tronTextMuted.opacity(0.7))

            // Restore button
            Button {
                Task {
                    await restoreTask(task)
                }
            } label: {
                Text("Restore")
                    .font(TronTypography.mono(size: 11, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tronEmerald.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
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
                    await loadTodos()
                }
            }
            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            .foregroundStyle(.tronEmerald)
            .padding(.top, 8)
        }
    }

    // MARK: - Data Loading

    private func loadTodos() async {
        todoState.startLoading()

        do {
            let result = try await rpcClient.misc.listTodos(sessionId: sessionId)
            todoState.updateTodos(result.todos, summary: result.summary)

            // Also load backlog if we have a workspace ID
            if let workspaceId {
                todoState.startBacklogLoading()
                let backlogResult = try await rpcClient.misc.getBacklog(workspaceId: workspaceId)
                todoState.updateBacklog(backlogResult.tasks)
            }
        } catch {
            todoState.setError(error.localizedDescription)
        }
    }

    private func restoreTask(_ task: RpcBackloggedTask) async {
        // Optimistic UI - mark as pending restore
        todoState.markPendingRestore([task.id])

        do {
            let result = try await rpcClient.misc.restoreFromBacklog(sessionId: sessionId, taskIds: [task.id])

            // On success, clear pending state and update todos
            todoState.clearPendingRestore([task.id])

            // The server will send a todos_updated event which will update the todos
            // But we can also update optimistically here
            if !result.restoredTodos.isEmpty {
                var updatedTodos = todoState.todos
                updatedTodos.append(contentsOf: result.restoredTodos)
                todoState.updateTodos(updatedTodos)
            }
        } catch {
            // On failure, clear pending state (task reappears)
            todoState.clearPendingRestore([task.id])
        }
    }
}

// MARK: - Legacy Fallback

/// Fallback view for iOS versions before 26.0
struct TodoDetailSheetLegacy: View {
    let rpcClient: RPCClient
    let sessionId: String
    let workspaceId: String?
    @Bindable var todoState: TodoState

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if todoState.isLoading {
                    ProgressView()
                        .tint(.green)
                } else if todoState.todos.isEmpty {
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
                        ForEach(todoState.todos) { todo in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(todo.status == .inProgress ? todo.activeForm : todo.content)
                                    .font(.body)
                                    .foregroundStyle(todo.status == .completed ? .gray : .white)
                                HStack {
                                    Text(todo.source.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                    Text(todo.status.displayName)
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
                await loadTodos()
            }
        }
    }

    private func loadTodos() async {
        todoState.startLoading()
        do {
            let result = try await rpcClient.misc.listTodos(sessionId: sessionId)
            todoState.updateTodos(result.todos, summary: result.summary)
        } catch {
            todoState.setError(error.localizedDescription)
        }
    }
}

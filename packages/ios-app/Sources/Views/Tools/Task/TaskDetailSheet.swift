import SwiftUI

/// Sheet view for task manager chip taps — shows entity snapshot card for
/// create/update/get/delete actions, or raw result text for list/search actions.
@available(iOS 26.0, *)
struct TaskDetailSheet: View {
    let chipData: TaskManagerChipData

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    actionHeaderSection(chipData)

                    if let entity = chipData.entityDetail {
                        EntitySnapshotCard(entity: entity, action: chipData.action)
                    } else if let result = chipData.fullResult, !result.isEmpty {
                        rawResultSection(result)
                    } else {
                        waitingSection
                    }
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
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronSlate)
    }

    // MARK: - Action Header

    @ViewBuilder
    private func actionHeaderSection(_ chip: TaskManagerChipData) -> some View {
        HStack(spacing: 8) {
            // Action badge
            Text(chip.action.replacingOccurrences(of: "_", with: " "))
                .font(TronTypography.mono(size: 11, weight: .medium))
                .foregroundStyle(.tronSlate)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.tronSlate.opacity(0.15))
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

    // MARK: - Raw Result (list/search fallback)

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

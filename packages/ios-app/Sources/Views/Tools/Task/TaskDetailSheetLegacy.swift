import SwiftUI

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

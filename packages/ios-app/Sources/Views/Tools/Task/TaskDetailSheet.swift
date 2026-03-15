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

    private let accentColor: Color = .tronSlate

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Task Manager",
            iconName: "checklist",
            accent: .tronSlate
        ) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    actionHeaderSection(chipData)
                    contentSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Content Routing

    @ViewBuilder
    private var contentSection: some View {
        if let entity = chipData.entityDetail {
            // Entity actions: create, update, get, delete, log_time (+ project/area variants)
            EntitySnapshotCard(entity: entity, action: chipData.action)
        } else if let batchResult = chipData.batchResult {
            // Batch actions: batch_create, batch_delete, batch_update
            batchResultSection(batchResult)
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
                        .font(TronTypography.sans(size: TronTypography.sizeBody2))
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
                Text(item.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(item.mark == "x" ? .tronTextMuted : .tronTextPrimary)
                    .strikethrough(item.mark == "x", color: .tronTextMuted)
                    .lineLimit(2)

                Text(item.taskId)
                    .font(TronTypography.mono(size: 10, weight: .regular))
                    .foregroundStyle(.tronTextMuted.opacity(0.6))
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
                        .font(TronTypography.sans(size: TronTypography.sizeBody2))
                        .foregroundStyle(.tronTextMuted)
                    Text("Search Results")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    countPill(items.count)
                    Spacer()
                }

                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        statusDot(for: TaskFormatting.statusMark(item.status))

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

    // MARK: - Batch Result

    @ViewBuilder
    private func batchResultSection(_ result: BatchResult) -> some View {
        glassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronSuccess)

                    Text("Batch Create")
                        .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("\(result.affected)")
                        .font(TronTypography.mono(size: 28, weight: .bold))
                        .foregroundStyle(.tronSuccess)

                    Text("task\(result.affected == 1 ? "" : "s") created")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                        .foregroundStyle(.tronTextSecondary)
                }

                if !result.ids.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Created IDs")
                            .font(TronTypography.mono(size: 11, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)

                        ForEach(result.ids, id: \.self) { taskId in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.tronSuccess.opacity(0.6))
                                    .frame(width: 5, height: 5)
                                Text(taskId)
                                    .font(TronTypography.mono(size: 11, weight: .regular))
                                    .foregroundStyle(.tronTextSecondary)
                            }
                        }
                    }
                    .padding(.top, 4)
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
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
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
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
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
        let color = TaskFormatting.statusColor(status)
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
    private func statusDot(for mark: String) -> some View {
        let color: Color = switch mark {
        case "x": .tronSuccess
        case ">": .tronTeal
        case "-": .tronError
        case "?": .tronAmber
        default: .tronSlate.opacity(0.5)
        }
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .padding(.top, 5)
    }

}

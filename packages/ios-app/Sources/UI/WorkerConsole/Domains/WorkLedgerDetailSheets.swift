import SwiftUI

struct WorkLedgerGoalDetailSheet: View {
    let goalId: String
    @Bindable var viewModel: WorkLedgerViewModel
    let workerId: String
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var cancelReason = ""
    @State private var confirmComplete = false
    @State private var confirmCancel = false

    private var goal: WorkLedgerGoal? {
        viewModel.snapshot.goals.first { $0.id == goalId }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = viewModel.lastError {
                        WorkerConsoleErrorBanner(message: error)
                    }
                    if let goal {
                        overview(goal)
                        editing(goal)
                        linkedWork(goal)
                        activity
                        lifecycle(goal)
                    } else {
                        WorkerConsoleEmptyState(
                            symbol: "exclamationmark.triangle",
                            title: "Goal unavailable",
                            detail: "The goal may have changed. Refresh Work Ledger and try again."
                        )
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Goal", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .confirmationDialog(
                "Complete this goal?",
                isPresented: $confirmComplete,
                titleVisibility: .visible
            ) {
                Button("Complete goal") { Task { await complete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The goal and its history will remain available.")
            }
            .confirmationDialog(
                "Cancel this goal?",
                isPresented: $confirmCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel goal", role: .destructive) { Task { await cancel() } }
                Button("Keep goal", role: .cancel) {}
            } message: {
                Text("The cancellation and its reason will remain in durable history.")
            }
            .onAppear { syncFields() }
            .onChange(of: goal) { _, _ in syncFields() }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }

    private func overview(_ goal: WorkLedgerGoal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: WorkLedgerPresentation.goalSymbol(goal.status))
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(WorkLedgerPresentation.statusColor(goal.status))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.title)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(WorkerConsolePresentation.displayLabel(goal.status))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(WorkLedgerPresentation.statusColor(goal.status))
                }
                Spacer(minLength: 0)
            }
            if !goal.description.isEmpty {
                Text(goal.description)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextSecondary)
            }
            if let updated = WorkerConsolePresentation.timestamp(goal.updatedAt) {
                Label("Updated \(updated)", systemImage: "clock")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(14)
        .sectionFill(
            WorkLedgerPresentation.statusColor(goal.status),
            cornerRadius: 12,
            subtle: true,
            interactive: false
        )
    }

    private func editing(_ goal: WorkLedgerGoal) -> some View {
        WorkerConsoleSection(
            title: "Details",
            detail: "Edit the useful outcome without replacing its stable identity.",
            accent: .tronEmerald
        ) {
            VStack(spacing: 13) {
                WorkLedgerFormField(title: "Title", text: $title, axis: .horizontal)
                WorkLedgerFormField(title: "Description", text: $description, axis: .vertical)
                WorkerLifecycleButton(
                    title: "Save changes",
                    symbol: "checkmark.circle",
                    color: .tronEmerald,
                    isEnabled: hasEdits(goal) && !viewModel.isMutating
                ) {
                    Task { await save() }
                }
            }
        }
    }

    private func linkedWork(_ goal: WorkLedgerGoal) -> some View {
        let questions = viewModel.snapshot.questions.filter { $0.goalId == goal.id }
        let decisions = viewModel.snapshot.decisions.filter { $0.goalId == goal.id }
        return WorkerConsoleSection(
            title: "Linked work",
            detail: "Questions and decisions attached to this goal.",
            accent: .tronCyan
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if questions.isEmpty && decisions.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "link",
                        text: "No questions or decisions are linked to this goal."
                    )
                } else {
                    ForEach(questions) { question in
                        Label(question.text, systemImage: "questionmark.bubble")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                    }
                    ForEach(decisions) { decision in
                        Label(decision.title, systemImage: "signpost.right.and.left")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
            }
        }
    }

    private var activity: some View {
        let entries = viewModel.snapshot.recentHistory.filter { $0.entityId == goalId }
        return WorkerConsoleSection(
            title: "Activity",
            detail: "Recent durable changes to this goal.",
            accent: .tronSlate
        ) {
            if entries.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "clock", text: "No recent activity retained.")
            } else {
                VStack(spacing: 9) {
                    ForEach(entries) { WorkLedgerHistoryRow(entry: $0) }
                }
            }
        }
    }

    private func lifecycle(_ goal: WorkLedgerGoal) -> some View {
        WorkerConsoleSection(
            title: "Lifecycle",
            detail: "Completion and cancellation preserve the full record.",
            accent: goal.status == "active" ? .tronEmerald : .tronTextMuted
        ) {
            if goal.status == "active" {
                VStack(spacing: 10) {
                    WorkerLifecycleButton(
                        title: "Complete goal",
                        symbol: "checkmark.circle",
                        color: .tronSuccess,
                        isEnabled: !viewModel.isMutating,
                        action: { confirmComplete = true }
                    )
                    WorkLedgerFormField(
                        title: "Cancellation reason",
                        text: $cancelReason,
                        axis: .vertical
                    )
                    WorkerLifecycleButton(
                        title: "Cancel goal",
                        symbol: "xmark.circle",
                        color: .tronError,
                        isEnabled: !viewModel.isMutating,
                        action: { confirmCancel = true }
                    )
                }
            } else {
                Label(
                    goal.status == "completed" ? "This goal is complete." : "This goal was cancelled.",
                    systemImage: WorkLedgerPresentation.goalSymbol(goal.status)
                )
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(WorkLedgerPresentation.statusColor(goal.status))
            }
        }
    }

    private func hasEdits(_ goal: WorkLedgerGoal) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (title != goal.title || description != goal.description)
    }

    private func syncFields() {
        guard let goal else { return }
        title = goal.title
        description = goal.description
    }

    private func save() async {
        _ = await viewModel.updateGoal(
            goalId: goalId,
            title: title,
            description: description,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func complete() async {
        _ = await viewModel.completeGoal(
            goalId,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func cancel() async {
        _ = await viewModel.cancelGoal(
            goalId,
            reason: cancelReason,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }
}

struct WorkLedgerQuestionDetailSheet: View {
    let questionId: String
    @Bindable var viewModel: WorkLedgerViewModel
    let workerId: String
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    @State private var answer = ""
    @State private var confirmResolve = false

    private var question: WorkLedgerQuestion? {
        viewModel.snapshot.questions.first { $0.id == questionId }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error = viewModel.lastError {
                        WorkerConsoleErrorBanner(message: error)
                    }
                    if let question {
                        overview(question)
                        answerSection(question)
                        activity
                    } else {
                        WorkerConsoleEmptyState(
                            symbol: "exclamationmark.triangle",
                            title: "Question unavailable",
                            detail: "Refresh Work Ledger and try again."
                        )
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Question", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
            .confirmationDialog(
                "Resolve this question?",
                isPresented: $confirmResolve,
                titleVisibility: .visible
            ) {
                Button("Resolve question") { Task { await resolve() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The question and its answer will remain in history.")
            }
            .onAppear { answer = question?.answer ?? "" }
            .onChange(of: question) { _, newValue in answer = newValue?.answer ?? answer }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronCyan)
    }

    private func overview(_ question: WorkLedgerQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "questionmark.bubble")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(WorkLedgerPresentation.statusColor(question.status))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.text)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(WorkerConsolePresentation.displayLabel(question.status))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(WorkLedgerPresentation.statusColor(question.status))
                }
            }
            if let goalId = question.goalId,
               let goal = viewModel.snapshot.goals.first(where: { $0.id == goalId }) {
                Label(goal.title, systemImage: "target")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        .padding(14)
        .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func answerSection(_ question: WorkLedgerQuestion) -> some View {
        WorkerConsoleSection(
            title: "Answer",
            detail: "Record an answer, then resolve the question when no follow-up remains.",
            accent: .tronCyan
        ) {
            VStack(spacing: 11) {
                WorkLedgerFormField(title: "Answer", text: $answer, axis: .vertical)
                if question.status != "resolved" {
                    WorkerLifecycleButton(
                        title: question.answer == nil ? "Record answer" : "Update answer",
                        symbol: "text.bubble",
                        color: .tronCyan,
                        isEnabled: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && answer != question.answer
                            && !viewModel.isMutating
                    ) {
                        Task { await saveAnswer() }
                    }
                    WorkerLifecycleButton(
                        title: "Resolve question",
                        symbol: "checkmark.circle",
                        color: .tronSuccess,
                        isEnabled: !viewModel.isMutating,
                        action: { confirmResolve = true }
                    )
                } else {
                    Label("This question is resolved.", systemImage: "checkmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronSuccess)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var activity: some View {
        let entries = viewModel.snapshot.recentHistory.filter { $0.entityId == questionId }
        return WorkerConsoleSection(
            title: "Activity",
            detail: "Recent durable changes to this question.",
            accent: .tronSlate
        ) {
            if entries.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "clock", text: "No recent activity retained.")
            } else {
                VStack(spacing: 9) {
                    ForEach(entries) { WorkLedgerHistoryRow(entry: $0) }
                }
            }
        }
    }

    private func saveAnswer() async {
        _ = await viewModel.answerQuestion(
            questionId,
            answer: answer,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func resolve() async {
        _ = await viewModel.resolveQuestion(
            questionId,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }
}

struct WorkLedgerDecisionDetailSheet: View {
    let decisionId: String
    @Bindable var viewModel: WorkLedgerViewModel

    private var decision: WorkLedgerDecision? {
        viewModel.snapshot.decisions.first { $0.id == decisionId }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let decision {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(decision.title, systemImage: "signpost.right.and.left")
                                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                                .foregroundStyle(.tronTextPrimary)
                            if !decision.rationale.isEmpty {
                                Text(decision.rationale)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronTextSecondary)
                            }
                            if let goalId = decision.goalId,
                               let goal = viewModel.snapshot.goals.first(where: { $0.id == goalId }) {
                                WorkerMetadataRow(label: "Goal", value: goal.title)
                            }
                            if let questionId = decision.questionId,
                               let question = viewModel.snapshot.questions.first(where: { $0.id == questionId }) {
                                WorkerMetadataRow(label: "Question", value: question.text)
                            }
                            if let created = WorkerConsolePresentation.timestamp(decision.createdAt) {
                                WorkerMetadataRow(label: "Recorded", value: created)
                            }
                        }
                        .padding(14)
                        .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)

                        activity
                    } else {
                        WorkerConsoleEmptyState(
                            symbol: "exclamationmark.triangle",
                            title: "Decision unavailable",
                            detail: "Refresh Work Ledger and try again."
                        )
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Decision", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
    }

    private var activity: some View {
        let entries = viewModel.snapshot.recentHistory.filter { $0.entityId == decisionId }
        return WorkerConsoleSection(
            title: "Activity",
            detail: "Recent durable changes to this decision.",
            accent: .tronSlate
        ) {
            if entries.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "clock", text: "No recent activity retained.")
            } else {
                VStack(spacing: 9) {
                    ForEach(entries) { WorkLedgerHistoryRow(entry: $0) }
                }
            }
        }
    }
}

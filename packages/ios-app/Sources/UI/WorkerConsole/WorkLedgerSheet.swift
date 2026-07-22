import SwiftUI

private enum WorkLedgerSection: String, CaseIterable {
    case goals = "Goals"
    case questions = "Questions"
    case decisions = "Decisions"
    case activity = "Activity"
}

enum WorkLedgerCreateKind: String, CaseIterable, Identifiable {
    case goal = "Goal"
    case question = "Question"
    case decision = "Decision"

    var id: String { rawValue }
}

private enum WorkLedgerGoalFilter: String, CaseIterable {
    case active = "Active"
    case all = "All"
    case completed = "Done"
    case cancelled = "Cancelled"
}

private enum WorkLedgerQuestionFilter: String, CaseIterable {
    case open = "Open"
    case all = "All"
    case answered = "Answered"
    case resolved = "Resolved"
}

struct WorkLedgerSheet: View {
    @Bindable var consoleViewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    @State private var viewModel = WorkLedgerViewModel()
    @State private var selectedSection = WorkLedgerSection.goals
    @State private var goalFilter = WorkLedgerGoalFilter.active
    @State private var questionFilter = WorkLedgerQuestionFilter.open
    @State private var createKind: WorkLedgerCreateKind?
    @State private var selectedGoalId: String?
    @State private var selectedQuestionId: String?
    @State private var selectedDecisionId: String?
    @State private var showTechnicalDetails = false

    private var workerId: String {
        consoleViewModel.selectedWorker?.workerId ?? "work-ledger"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    TronSegmentedControl(
                        options: WorkLedgerSection.allCases.map { ($0.rawValue, $0) },
                        selection: $selectedSection,
                        accent: .tronEmerald
                    )

                    if let error = viewModel.lastError {
                        WorkerConsoleErrorBanner(message: error)
                    }

                    content
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Work Ledger", color: .tronEmerald)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isLoading,
                        accessibilityLabel: "Refresh Work Ledger"
                    ) {
                        Task { await refresh() }
                    }
                    Button {
                        showTechnicalDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                    .accessibilityLabel("Open worker contract and controls")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        createKind = defaultCreateKind
                    } label: {
                        Image(systemName: "plus")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                    .disabled(viewModel.isMutating || !connectionState.isConnected)
                    .accessibilityLabel("Add to Work Ledger")
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .sheet(item: $createKind) { kind in
                WorkLedgerCreateSheet(
                    kind: kind,
                    viewModel: viewModel,
                    workerId: workerId,
                    repository: repository,
                    connectionState: connectionState
                )
            }
            .sheet(isPresented: $showTechnicalDetails) {
                WorkerDetailSheet(
                    viewModel: consoleViewModel,
                    repository: repository,
                    connectionState: connectionState,
                    mode: .technical
                )
            }
            .sheet(isPresented: goalPresented) {
                if let selectedGoalId {
                    WorkLedgerGoalDetailSheet(
                        goalId: selectedGoalId,
                        viewModel: viewModel,
                        workerId: workerId,
                        repository: repository,
                        connectionState: connectionState
                    )
                }
            }
            .sheet(isPresented: questionPresented) {
                if let selectedQuestionId {
                    WorkLedgerQuestionDetailSheet(
                        questionId: selectedQuestionId,
                        viewModel: viewModel,
                        workerId: workerId,
                        repository: repository,
                        connectionState: connectionState
                    )
                }
            }
            .sheet(isPresented: decisionPresented) {
                if let selectedDecisionId {
                    WorkLedgerDecisionDetailSheet(
                        decisionId: selectedDecisionId,
                        viewModel: viewModel
                    )
                }
            }
            .task { await refresh() }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checklist")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Durable work state")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("Goals, open questions, and decisions preserved across sessions.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                summaryMetric(viewModel.snapshot.activeGoalCount, "Active goals")
                summaryDivider
                summaryMetric(viewModel.snapshot.openQuestionCount, "Open questions")
                summaryDivider
                summaryMetric(viewModel.snapshot.decisionCount, "Decisions")
            }
        }
        .padding(14)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    @ViewBuilder
    private var content: some View {
        if !connectionState.isConnected {
            WorkerConsoleEmptyState(
                symbol: "network.slash",
                title: "Work Ledger is offline",
                detail: "Reconnect to the paired server to view or change durable work state."
            )
        } else if !viewModel.hasLoaded && viewModel.isLoading {
            WorkerConsoleLoadingState(title: "Loading Work Ledger")
        } else {
            switch selectedSection {
            case .goals: goalsContent
            case .questions: questionsContent
            case .decisions: decisionsContent
            case .activity: activityContent
            }
        }
    }

    private var goalsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Goals",
                detail: "Useful outcomes and their durable lifecycle."
            )
            TronSegmentedControl(
                options: WorkLedgerGoalFilter.allCases.map { ($0.rawValue, $0) },
                selection: $goalFilter,
                accent: .tronEmerald
            )
            if filteredGoals.isEmpty {
                WorkerConsoleEmptyState(
                    symbol: "target",
                    title: goalFilter == .active ? "No active goals" : "No matching goals",
                    detail: "Create a goal here or ask Tron to record one while you work."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredGoals) { goal in
                        Button { selectedGoalId = goal.id } label: {
                            WorkLedgerGoalRow(
                                goal: goal,
                                questionCount: viewModel.snapshot.questions.count { $0.goalId == goal.id }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var questionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Questions",
                detail: "Open decisions and answers attached to the work that raised them."
            )
            TronSegmentedControl(
                options: WorkLedgerQuestionFilter.allCases.map { ($0.rawValue, $0) },
                selection: $questionFilter,
                accent: .tronCyan
            )
            if filteredQuestions.isEmpty {
                WorkerConsoleEmptyState(
                    symbol: "questionmark.bubble",
                    title: questionFilter == .open ? "No open questions" : "No matching questions",
                    detail: "Capture unresolved questions so they remain visible across sessions."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filteredQuestions) { question in
                        Button { selectedQuestionId = question.id } label: {
                            WorkLedgerQuestionRow(
                                question: question,
                                goalTitle: goalTitle(question.goalId)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var decisionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Decisions",
                detail: "Durable choices and the rationale behind them."
            )
            if viewModel.snapshot.decisions.isEmpty {
                WorkerConsoleEmptyState(
                    symbol: "signpost.right.and.left",
                    title: "No decisions recorded",
                    detail: "Record consequential choices with enough rationale to reuse later."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.snapshot.decisions) { decision in
                        Button { selectedDecisionId = decision.id } label: {
                            WorkLedgerDecisionRow(
                                decision: decision,
                                goalTitle: goalTitle(decision.goalId)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkerConsoleSectionHeader(
                title: "Recent activity",
                detail: "The latest durable record changes from every session."
            )
            if viewModel.snapshot.recentHistory.isEmpty {
                WorkerConsoleEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "No ledger activity",
                    detail: "Changes will appear here after goals, questions, or decisions are recorded."
                )
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.snapshot.recentHistory) { entry in
                        WorkLedgerHistoryRow(entry: entry)
                    }
                }
            }
        }
    }

    private func sectionHeader(
        title: String,
        detail: String
    ) -> some View {
        WorkerConsoleSectionHeader(title: title, detail: detail)
    }

    private var filteredGoals: [WorkLedgerGoal] {
        guard goalFilter != .all else { return viewModel.snapshot.goals }
        return viewModel.snapshot.goals.filter { $0.status == goalFilter.rawValue.lowercased() }
    }

    private var filteredQuestions: [WorkLedgerQuestion] {
        guard questionFilter != .all else { return viewModel.snapshot.questions }
        return viewModel.snapshot.questions.filter { $0.status == questionFilter.rawValue.lowercased() }
    }

    private var defaultCreateKind: WorkLedgerCreateKind {
        switch selectedSection {
        case .goals, .activity: .goal
        case .questions: .question
        case .decisions: .decision
        }
    }

    private var goalPresented: Binding<Bool> {
        Binding(get: { selectedGoalId != nil }, set: { if !$0 { selectedGoalId = nil } })
    }

    private var questionPresented: Binding<Bool> {
        Binding(get: { selectedQuestionId != nil }, set: { if !$0 { selectedQuestionId = nil } })
    }

    private var decisionPresented: Binding<Bool> {
        Binding(get: { selectedDecisionId != nil }, set: { if !$0 { selectedDecisionId = nil } })
    }

    private func goalTitle(_ id: String?) -> String? {
        guard let id else { return nil }
        return viewModel.snapshot.goals.first { $0.id == id }?.title
    }

    private func summaryMetric(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Color.tronBorder.opacity(0.7))
            .frame(width: 1, height: 32)
    }

    private func refresh() async {
        await viewModel.refresh(
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }
}

struct WorkLedgerCreateSheet: View {
    let kind: WorkLedgerCreateKind
    @Bindable var viewModel: WorkLedgerViewModel
    let workerId: String
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var linkedGoalId = ""
    @State private var linkedQuestionId = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = viewModel.lastError {
                        WorkerConsoleErrorBanner(message: error)
                    }
                    fields
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "New \(kind.rawValue)", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.tronTextSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .disabled(!canSave || viewModel.isMutating)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .goal:
            WorkLedgerFormField(title: "Title", text: $title, axis: .horizontal)
            WorkLedgerFormField(title: "Description", text: $bodyText, axis: .vertical)
        case .question:
            WorkLedgerFormField(title: "Question", text: $bodyText, axis: .vertical)
            goalPicker
        case .decision:
            WorkLedgerFormField(title: "Decision", text: $title, axis: .horizontal)
            WorkLedgerFormField(title: "Rationale", text: $bodyText, axis: .vertical)
            goalPicker
            questionPicker
        }
    }

    private var goalPicker: some View {
        WorkLedgerPickerCard(title: "Related goal", selection: $linkedGoalId) {
            Text("None").tag("")
            ForEach(viewModel.snapshot.goals) { goal in
                Text(goal.title).tag(goal.id)
            }
        }
    }

    private var questionPicker: some View {
        WorkLedgerPickerCard(title: "Related question", selection: $linkedQuestionId) {
            Text("None").tag("")
            ForEach(viewModel.snapshot.questions) { question in
                Text(question.text).tag(question.id)
            }
        }
    }

    private var canSave: Bool {
        switch kind {
        case .goal, .decision: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .question: !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() async {
        let success: Bool
        switch kind {
        case .goal:
            success = await viewModel.createGoal(
                title: title,
                description: bodyText,
                workerId: workerId,
                repository: repository,
                connectionState: connectionState
            )
        case .question:
            success = await viewModel.createQuestion(
                text: bodyText,
                goalId: linkedGoalId.nilIfEmpty,
                workerId: workerId,
                repository: repository,
                connectionState: connectionState
            )
        case .decision:
            success = await viewModel.recordDecision(
                title: title,
                rationale: bodyText,
                goalId: linkedGoalId.nilIfEmpty,
                questionId: linkedQuestionId.nilIfEmpty,
                workerId: workerId,
                repository: repository,
                connectionState: connectionState
            )
        }
        if success { dismiss() }
    }
}

struct WorkLedgerFormField: View {
    let title: String
    @Binding var text: String
    let axis: Axis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
            TextField(title, text: $text, axis: axis)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(axis == .vertical ? 3 ... 8 : 1 ... 1)
                .padding(12)
                .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: true)
        }
    }
}

struct WorkLedgerPickerCard<Content: View>: View {
    let title: String
    @Binding var selection: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: true)
        }
    }
}

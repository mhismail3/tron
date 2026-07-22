import SwiftUI

/// Stable sheet destination for unbounded JSON and other technical payloads.
struct WorkerJSONDetailSheet: View {
    let title: String
    let value: AnyCodable
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                WorkerJSONBlock(value: value, accent: accent)
                    .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
    }
}

/// Stable sheet destination for unbounded human-readable detail.
struct WorkerTextDetailSheet: View {
    let title: String
    let values: [String]
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Text(value)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(accent, cornerRadius: 10, subtle: true, interactive: false)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
    }
}

/// Canonical detail destination for a durable worker invocation.
struct WorkerRunDetailSheet: View {
    let run: WorkerInvocationDTO
    var workerName: String?
    var onCancel: (() -> Void)?

    @State private var showAuditSession = false
    @State private var confirmCancel = false

    private var color: Color {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    execution
                    WorkerConsoleSection(
                        title: "Input",
                        detail: "Typed input admitted for this invocation.",
                        accent: .tronInfo
                    ) {
                        WorkerJSONBlock(value: run.input, accent: .tronInfo)
                    }
                    if let output = run.output {
                        WorkerConsoleSection(
                            title: "Output",
                            detail: "Durable terminal output recorded by the dispatcher.",
                            accent: color
                        ) {
                            WorkerJSONBlock(value: output, accent: color)
                        }
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Worker Run", color: color)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    if run.agentSessionId != nil {
                        SheetPrimaryActionButton(
                            icon: "text.bubble",
                            accent: .tronPurple,
                            accessibilityLabel: "Open worker session"
                        ) {
                            showAuditSession = true
                        }
                    }
                    if canCancel, onCancel != nil {
                        SheetPrimaryActionButton(
                            icon: "stop.fill",
                            accent: .tronError,
                            accessibilityLabel: "Cancel worker run"
                        ) {
                            confirmCancel = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: color)
                }
            }
            .sheet(isPresented: $showAuditSession) {
                if let sessionId = run.agentSessionId {
                    WorkerAuditSessionSheet(sessionId: sessionId)
                }
            }
            .confirmationDialog(
                "Cancel this worker run?",
                isPresented: $confirmCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel run", role: .destructive) { onCancel?() }
                Button("Keep running", role: .cancel) {}
            } message: {
                Text("Only this invocation will stop. Other work and the worker route remain active.")
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(color)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workerName ?? WorkerConsolePresentation.displayLabel(run.status))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(WorkerConsolePresentation.runSummary(run) ?? "No result summary was recorded.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
            }
            if let error = run.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var execution: some View {
        WorkerConsoleSection(
            title: "Execution",
            detail: "Kernel-owned identity, delivery, trigger, and causal evidence.",
            accent: .tronSlate
        ) {
            VStack(spacing: 0) {
                row("Invocation", WorkerConsolePresentation.compactIdentifier(run.invocationId, length: 18), code: true)
                WorkerMetadataDivider()
                row("Version", WorkerConsolePresentation.compactIdentifier(run.workerVersion, length: 12), code: true)
                WorkerMetadataDivider()
                row("Status", WorkerConsolePresentation.displayLabel(run.status))
                WorkerMetadataDivider()
                row("Trigger", WorkerConsolePresentation.displayLabel(run.triggerKind))
                WorkerMetadataDivider()
                row("Attempts", "\(run.attemptCount)")
                WorkerMetadataDivider()
                row("Causal depth", "\(run.causalDepth)")
                if let created = WorkerConsolePresentation.timestamp(run.createdAt) {
                    WorkerMetadataDivider()
                    row("Created", created)
                }
                if let completed = WorkerConsolePresentation.timestamp(run.completedAt) {
                    WorkerMetadataDivider()
                    row("Completed", completed)
                }
                if let sessionId = run.agentSessionId {
                    WorkerMetadataDivider()
                    row("Worker session", sessionId, code: true)
                }
                WorkerMetadataDivider()
                row("Trace", run.traceId, code: true)
                WorkerMetadataDivider()
                row("Idempotency", run.idempotencyKey, code: true)
            }
        }
    }

    private func row(_ label: String, _ value: String, code: Bool = false) -> some View {
        WorkerMetadataRow(label: label, value: value, isCode: code)
    }

    private var canCancel: Bool {
        run.status == "queued" || run.status == "running"
    }

    private var statusSymbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        case "running": "waveform.path.ecg"
        default: "clock"
        }
    }
}

/// Read-only presentation for an agent-runner child session.
struct WorkerAuditSessionSheet: View {
    @Environment(\.dependencies) private var dependencies
    let sessionId: String

    var body: some View {
        NavigationStack {
            ChatView(
                services: dependencies.chatSessionServices,
                sessionId: sessionId,
                presentationMode: .workerAudit
            )
            .id(sessionId)
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronPurple)
    }
}

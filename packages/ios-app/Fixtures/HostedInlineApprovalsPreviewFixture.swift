#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Design-only simulator preview for #1641/#1643/#1644: the in-chat approval
/// request chip and sheet and the settings outcome chips and sheet, built from the
/// shared chat pill and sheet components. Values are synthetic; no Gateway,
/// receipts or decisions are simulated.
@MainActor
struct HostedInlineApprovalsPreview: View {
    let surface: String
    let dark: Bool
    @State private var sheetPresented: Bool
    @State private var detent: PresentationDetent = .large

    init(surface: String, dark: Bool) {
        self.surface = surface
        self.dark = dark
        _sheetPresented = State(initialValue: surface != "chat")
    }

    var body: some View {
        chat
            .tronManagedSheet(isPresented: $sheetPresented, identity: "preview.inline-approvals.\(surface)") {
                sheet
                    .tronTopBlur(.toolDetail)
                    .tronPresentation()
                    .presentationDetents([.medium, .large], selection: $detent)
                    .presentationDragIndicator(.hidden)
            }
            .preferredColorScheme(dark ? .dark : .light)
    }

    // MARK: Chat

    private var chat: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PromptTextPreview(text: "Put the settings worker on the reasoning model for the migration step.")
                    .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                    .padding(.top, ChatPromptContainerStyle.topPadding)
                    .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                    .modifier(UserPromptGlassModifier())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                TronMarkdownView(text: "Switching a worker's model and thinking needs your approval. I've asked below; the worker keeps its current settings until you decide.", streaming: false)
                PreviewChip(state: .waiting, title: "Model, Thinking", detail: "Waiting for you · 2 changes")
                    .accessibilityIdentifier("preview-request-chip")
                PreviewChip(state: .waiting, title: "Create project demo", detail: "Waiting for you · 1 action")
                Divider().padding(.vertical, 4)
                Text("Outcome events (each starts its own Home turn)")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                PreviewChip(state: .applied, title: "Model, Thinking", detail: "Approved · applied")
                PreviewChip(state: .applied, title: "Retries", detail: "Applied · notified you")
                PreviewChip(state: .denied, title: "Trust: tron-website", detail: "Denied")
                PreviewChip(state: .failed, title: "Thinking", detail: "Failed · worker busy")
                PreviewChip(state: .expired, title: "Context window", detail: "Expired · 24 h")
                PreviewChip(state: .superseded, title: "Tools", detail: "Superseded")
                PreviewChip(state: .interrupted, title: "Create project demo", detail: "Interrupted · effects uncertain")
                PreviewChip(state: .superseded, title: "Settings outcomes", detail: "3 requests · mixed outcomes")
                TronMarkdownView(text: "You approved the model switch; the worker uses GPT-6.1 Sol from its next request.", streaming: false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(Color.tronBackground)
        .safeAreaInset(edge: .bottom) { previewLabel }
    }

    private var previewLabel: some View {
        Text("Design preview · Synthetic values")
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
    }

    // MARK: Sheets

    @ViewBuilder private var sheet: some View {
        switch surface {
        case "request-single": RequestSheet(request: .trust, decided: nil)
        case "request-grant": RequestSheet(request: .grant, decided: nil)
        case "request-action": RequestSheet(request: .project, decided: nil)
        case "request-approved": RequestSheet(request: .worker, decided: .applied)
        case "outcome-applied": OutcomeSheet(outcome: .applied)
        case "outcome-denied": OutcomeSheet(outcome: .denied)
        case "outcome-failed": OutcomeSheet(outcome: .failed)
        case "outcome-expired": OutcomeSheet(outcome: .expired)
        case "outcome-action-interrupted": OutcomeSheet(outcome: .interrupted)
        case "outcome-batch": OutcomeBatchSheet()
        default: RequestSheet(request: .worker, decided: nil)
        }
    }
}

// MARK: - Shared preview vocabulary

private enum PreviewState {
    case waiting, applied, denied, failed, expired, superseded, interrupted

    var icon: String {
        switch self {
        case .waiting: "checkmark.shield"
        case .applied: "checkmark.circle.fill"
        case .denied: "hand.raised.fill"
        case .failed, .interrupted: "exclamationmark.triangle.fill"
        case .expired: "clock.badge.xmark"
        case .superseded: "arrow.triangle.2.circlepath"
        }
    }

    var tone: ChatNotificationTone {
        switch self {
        case .waiting: .warning
        case .applied: .accent
        case .failed, .interrupted: .error
        case .denied, .expired, .superseded: .neutral
        }
    }

    var accent: Color {
        switch self {
        case .waiting: .tronWarning
        case .applied: .tronEmerald
        case .failed, .interrupted: .tronError
        case .denied, .expired, .superseded: .tronSlate
        }
    }
}

private struct PreviewChip: View {
    let state: PreviewState
    let title: String
    let detail: String

    var body: some View {
        ChatCompactPillSurface(tone: state.tone, material: .glass, interactive: true,
                               cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius) {
            ChatCompactPillLabel(icon: state.icon, title: title, detail: detail, tone: state.tone,
                                 iconSize: ChatCompactPillLayoutPolicy.toolIconSize)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }
}

private struct PreviewChange: Identifiable {
    let id = UUID()
    let label: String
    let qualifier: String?
    let before: String
    let after: String
    let scope: String
    let effect: String
    let why: String
    let affects: String
}

private struct PreviewAction {
    let title: String
    let items: [(label: String, value: String)]

    static let project = PreviewAction(title: "Create project demo", items: [
        ("Folder", "~/Workspace/demo"),
        ("Git", "New repository · main branch"),
        ("Trust", "Not changed by this action"),
    ])
}

private struct PreviewRequest {
    let requester: String
    let reason: String
    let target: String
    let expires: String
    let changes: [PreviewChange]
    var grant: (intent: String, project: String)? = nil
    var action: PreviewAction? = nil

    static let project = PreviewRequest(
        requester: "Tron Home",
        reason: "You asked for a separate demo project. This creates its folder and Git repository; it does not grant project trust.",
        target: "This Mac · ~/Workspace/demo", expires: "in 24 h · Fri 9:12 AM", changes: [], action: .project)

    static let worker = PreviewRequest(
        requester: "Tron Home",
        reason: "The migration step needs stronger reasoning; back to defaults when it reports.",
        target: "Worker · Settings three-layer simplify",
        expires: "in 23 h · Thu 4:31 PM",
        changes: [
            PreviewChange(label: "Model", qualifier: nil, before: "Claude Opus 5.5", after: "GPT-6.1 Sol",
                          scope: "Session override · this worker only", effect: "From its next model request",
                          why: "Floor: Approve (you set it for Model)", affects: "The model this worker answers with. Other chats and Home are unchanged."),
            PreviewChange(label: "Thinking", qualifier: "for GPT-6.1 Sol", before: "High", after: "Extra high",
                          scope: "Session override · this worker only", effect: "From its next model request",
                          why: "Widening · raised one step: web content read earlier in this run", affects: "How much the model reasons before answering. Slower and costlier per request."),
        ])

    static let trust = PreviewRequest(
        requester: "Tron Home",
        reason: "You asked me to fix the website build; the project is not trusted yet.",
        target: "This Mac · every chat in the project",
        expires: "in 24 h · Fri 9:12 AM",
        changes: [
            PreviewChange(label: "Trust project", qualifier: "~/Workspace/tron-website", before: "Not trusted", after: "Trusted",
                          scope: "Global · this Mac", effect: "After the project's resources reload",
                          why: "Widening · trust always needs your tap", affects: "Lets the project's own extensions, skills and settings run in its chats. Trust is not a sandbox."),
        ])

    static let grant = PreviewRequest(
        requester: "Tron Home",
        reason: "Delegating the website build fix; the project is outside the standing scope.",
        target: "One task · ~/Workspace/tron-website",
        expires: "in 24 h · Fri 9:12 AM",
        changes: [],
        grant: (intent: "Fix the static site build failing on the image pipeline", project: "~/Workspace/tron-website"))
}

private struct PreviewRow: View {
    let icon: String
    let title: String
    let value: String
    var accent: Color = .tronSlate

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: value, subtitleLineLimit: nil, accent: accent,
                        titleFont: TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold),
                        subtitleColor: .tronTextSecondary)
    }
}

private struct ChangeGroup: View {
    let change: PreviewChange
    let accent: Color
    var tookEffect = false
    /// An outcome shows what changed and where; a request also shows why and what it affects.
    var outcome: PreviewState? = nil

    var body: some View {
        TronSettingsGroup(change.label, detail: change.qualifier, accent: accent) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(change.before)
                        .foregroundStyle(Color.tronTextSecondary)
                        .strikethrough(tookEffect, color: .tronTextSecondary)
                    Image(systemName: "arrow.right").foregroundStyle(accent).accessibilityHidden(true)
                    Text(change.after).foregroundStyle(Color.tronTextPrimary)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .padding(16)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(change.before) to \(change.after)")
                TronSettingsDivider(accent: accent)
                PreviewRow(icon: "square.stack.3d.up", title: "Scope", value: change.scope, accent: accent)
                if outcome == nil || tookEffect {
                    TronSettingsDivider(accent: accent)
                    PreviewRow(icon: "clock", title: tookEffect ? "Took effect" : "Takes effect", value: change.effect, accent: accent)
                }
                if outcome == nil {
                    TronSettingsDivider(accent: accent)
                    PreviewRow(icon: "shield.lefthalf.filled", title: "Why approval", value: change.why, accent: accent)
                    TronSettingsDivider(accent: accent)
                    PreviewRow(icon: "info.circle", title: "What it affects", value: change.affects, accent: accent)
                }
            }
        }
    }
}

// MARK: - Request sheet

private struct RequestSheet: View {
    let request: PreviewRequest
    let decided: PreviewState?
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { decided?.accent ?? .tronWarning }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.section) {
                    header
                    if let grant = request.grant {
                        TronSettingsGroup("One-use task grant", accent: accent) {
                            PreviewRow(icon: "text.quote", title: "Task", value: grant.intent, accent: accent)
                            TronSettingsDivider(accent: accent)
                            PreviewRow(icon: "folder", title: "Project", value: grant.project, accent: accent)
                            TronSettingsDivider(accent: accent)
                            PreviewRow(icon: "lock.shield", title: "Binding", value: "This exact task and project, once. Consumed when the task starts; never renewed.", accent: accent)
                            TronSettingsDivider(accent: accent)
                            PreviewRow(icon: "info.circle", title: "What it affects", value: "A worker runs in this project with its trusted resources. The standing scope is unchanged.", accent: accent)
                        }
                    }
                    if let action = request.action { ActionGroup(action: action, accent: accent) }
                    ForEach(request.changes) { ChangeGroup(change: $0, accent: accent, tookEffect: decided == .applied, outcome: decided) }
                    note
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TronSheetInfoButton(accessibilityLabel: "Technical details", accent: accent) {}
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: decided == nil ? "Approve" : "Approved", accent: accent, icon: decided?.icon)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if decided == nil {
                        Button(role: .destructive) {} label: {
                            Image(systemName: "xmark").font(TronTypography.buttonSM).tronToolbarAction(role: .destructive)
                        }
                        .accessibilityLabel("Deny request")
                        .accessibilityIdentifier("preview-deny")
                        Button {} label: {
                            Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronSuccess)
                        }
                        .accessibilityLabel(request.changes.count > 1 ? "Approve \(request.changes.count) changes" : "Approve request")
                        .accessibilityIdentifier("preview-approve")
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: accent)
                        }
                        .accessibilityLabel("Done")
                    }
                }
            }
        }
    }

    private var header: some View {
        TronGlassCard(accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(request.requester) asks")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    Spacer(minLength: 8)
                    TronStatusPill(text: decided == nil ? "Waiting for you" : "Approved · applied", accent: accent)
                }
                Text("\u{201C}\(request.reason)\u{201D}")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            TronSettingsDivider(accent: accent)
            PreviewRow(icon: "scope", title: "Applies to", value: request.target, accent: accent)
            TronSettingsDivider(accent: accent)
            PreviewRow(icon: "hourglass", title: decided == nil ? "Expires" : "Decided",
                       value: decided == nil ? request.expires : "By you on iPhone · 4:12 PM", accent: accent)
        }
    }

    private var note: some View {
        Text(decided != nil ? "Tron Home was told in its own turn. Undo either change from Settings › Changes."
             : request.action != nil ? "Approving runs exactly this action once. It is not undoable from Settings › Changes. Only your tap decides; Tron Home cannot approve itself."
             : request.grant != nil ? "Approving mints one grant for exactly this task. Only your tap decides; \(request.requester) cannot approve its own request."
             : "Approving applies exactly these values. Only your tap decides; \(request.requester) cannot approve its own request. Undo any change from Settings › Changes.")
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

}

// MARK: - Outcome sheet

private struct OutcomeSheet: View {
    let outcome: PreviewState
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch outcome {
        case .applied: "Settings applied"
        case .denied: "Request denied"
        case .failed: "Change failed"
        case .interrupted: "Action interrupted"
        case .expired: "Request expired"
        default: "Settings outcome"
        }
    }

    private var summary: String {
        switch outcome {
        case .applied: "You approved Tron Home's request. Both changes are in effect for the worker."
        case .denied: "You denied Tron Home's request. Nothing changed."
        case .failed: "You approved it, but applying failed. Nothing changed; Tron Home can ask again."
        case .interrupted: "Execution began, but its result could not be confirmed. The action may have completed. Inspect the project before asking again."
        case .expired: "No decision within 24 hours. Nothing changed; Tron Home was told."
        default: ""
        }
    }

    private var changes: [PreviewChange] {
        outcome == .interrupted ? [] : outcome == .denied ? PreviewRequest.trust.changes : outcome == .expired ? [PreviewChange(
            label: "Context window", qualifier: "for Claude Opus 5.5", before: "200K", after: "1M",
            scope: "Home override", effect: "Next model request", why: "", affects: "How much conversation fits before compaction. Larger windows cost more per request.")]
            : PreviewRequest.worker.changes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.section) {
                    if outcome == .interrupted {
                        TronSettingsGroup("Outcome", accent: outcome.accent) {
                            PreviewRow(icon: outcome.icon, title: "Effects uncertain", value: summary, accent: outcome.accent)
                        }
                    } else {
                        ToolStaticChip(icon: outcome.icon, text: summary, accent: outcome.accent)
                    }
                    if outcome == .failed {
                        TronSettingsGroup("Why it failed", accent: outcome.accent) {
                            PreviewRow(icon: "exclamationmark.triangle", title: "Worker busy",
                                       value: "The worker was compacting its context. Its settings change between requests; nothing was written.", accent: outcome.accent)
                        }
                    }
                    if outcome == .interrupted {
                        ActionGroup(action: .project, accent: outcome.accent)
                        TronSettingsCaption("The same approval will not run this action again. Check the folder and repository before requesting another action.")
                    }
                    ForEach(changes) { ChangeGroup(change: $0, accent: outcome.accent, tookEffect: outcome == .applied, outcome: outcome) }
                    TronSettingsGroup("Request", accent: outcome.accent) {
                        PreviewRow(icon: "person.crop.circle", title: "Asked by", value: outcome == .interrupted ? "Tron Home" : "Tron Home · for Worker · Settings three-layer simplify", accent: outcome.accent)
                        TronSettingsDivider(accent: outcome.accent)
                        PreviewRow(icon: "text.quote", title: "Reason", value: outcome == .interrupted ? PreviewRequest.project.reason : PreviewRequest.worker.reason, accent: outcome.accent)
                        TronSettingsDivider(accent: outcome.accent)
                        PreviewRow(icon: "clock", title: "Timeline", value: outcome == .expired
                                   ? "Asked Wed 4:31 PM · expired Thu 4:31 PM"
                                   : outcome == .interrupted ? "Asked 4:02 PM · approved 4:12 PM · interrupted 4:13 PM"
                                   : "Asked 4:02 PM · \(outcome == .denied ? "denied" : "approved") by you 4:12 PM", accent: outcome.accent)
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TronSheetInfoButton(accessibilityLabel: "Technical details", accent: outcome.accent) {}
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: title, accent: outcome.accent, icon: outcome.icon)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: outcome.accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
    }
}

private struct ActionGroup: View {
    let action: PreviewAction
    let accent: Color

    var body: some View {
        TronSettingsGroup(action.title, accent: accent) {
            ForEach(Array(action.items.enumerated()), id: \.offset) { index, item in
                if index > 0 { TronSettingsDivider(accent: accent) }
                PreviewRow(icon: index == 0 ? "folder" : "info.circle", title: item.label, value: item.value, accent: accent)
            }
        }
    }
}

private struct OutcomeBatchSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.section) {
                    ToolStaticChip(icon: "slider.horizontal.3", text: "Three requests settled while Home was busy. Home hears them together in one turn.", accent: .tronSlate)
                    TronSettingsGroup("Retries", accent: .tronSuccess) {
                        PreviewRow(icon: "checkmark.circle.fill", title: "Approved · applied", value: "Global · 3 retries → 5 retries", accent: .tronSuccess)
                    }
                    TronSettingsGroup("Trust project", accent: .tronSlate) {
                        PreviewRow(icon: "hand.raised.fill", title: "Denied", value: "Nothing changed · ~/Workspace/tron-website", accent: .tronSlate)
                    }
                    TronSettingsGroup("Create project demo", accent: .tronError) {
                        PreviewRow(icon: "exclamationmark.triangle.fill", title: "Interrupted · effects uncertain", value: "Inspect the folder and repository before asking again. This approval will not execute twice.", accent: .tronError)
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { TronSheetInfoButton(accessibilityLabel: "Technical details", accent: .tronSlate) {} }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Settings outcomes", accent: .tronSlate, icon: "slider.horizontal.3") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronSlate) }
                        .accessibilityLabel("Done")
                }
            }
        }
    }
}
#endif

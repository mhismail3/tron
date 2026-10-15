import SwiftUI
import TronMobileCore

extension View {
    /// Shows the scope's pending settings changes directly below this view.
    func settingsApprovals(_ scope: SettingsApprovalScope, accent: Color = .tronEmerald) -> some View {
        SettingsApprovalsSection(scope: scope, accent: accent, anchor: self)
    }
}

/// Pending settings changes waiting for the maintainer (docs/settings-model.md
/// 5.5, 7.1-7.3). Calm by default: with nothing pending, or before a successful
/// read, it adds nothing, and a failed read stays silent rather than alarming a
/// surface that has no action to offer. It wraps an always-present anchor view
/// so its read runs while it shows nothing, without adding stack spacing.
private struct SettingsApprovalsSection<Anchor: View>: View {
    let scope: SettingsApprovalScope
    let accent: Color
    let anchor: Anchor
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var requests: [SettingsApprovalRequest] = []
    @State private var deciding: Set<String> = []
    @State private var loadGeneration = 0
    @State private var confirmation: PendingSettingsDecision?
    @State private var confirmationPresented = false
    @State private var noLongerWaiting = false

    private struct LoadID: Hashable {
        let scope: SettingsApprovalScope
        let revision: Int
        let foregroundGeneration: Int
        let stagedDecision: Int?
    }

    /// A settings push action, staged for one row, awaiting the maintainer's own tap.
    private struct PendingSettingsDecision {
        let request: SettingsApprovalRequest
        let approved: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            anchor
            if !requests.isEmpty {
                Text("Waiting for you")
                    .font(TronTypography.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings-approvals-header")
                ForEach(requests) { request in
                    requestCard(request)
                }
            }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { loadGeneration &+= 1 }
        }
        .onDisappear { loadGeneration &+= 1 }
        .confirmationDialog(
            confirmation?.approved == false ? "Decline this change?" : "Approve this change?",
            isPresented: $confirmationPresented,
            titleVisibility: .visible
        ) {
            if let pending = confirmation {
                if pending.approved {
                    Button("Approve change") { decide(pending.request, approved: true) }
                } else {
                    Button("Decline change", role: .destructive) { decide(pending.request, approved: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pending = confirmation { Text(Self.confirmationMessage(pending.request)) }
        }
        .alert("No longer waiting", isPresented: $noLongerWaiting) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This change was already decided or has expired.")
        }
        .task(id: PresentationActivityTaskID(
            source: LoadID(scope: scope, revision: model.settingsApprovalsRevision,
                           foregroundGeneration: model.foregroundReconciliationGeneration,
                           stagedDecision: model.stagedSettingsDecision?.id),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await load()
        }
    }

    private func requestCard(_ request: SettingsApprovalRequest) -> some View {
        let busy = deciding.contains(request.requestId)
        return TronGlassCard(accent: accent) {
            VStack(spacing: 0) {
                ForEach(request.changes) { change in
                    changeBlock(change, accent: accent)
                    TronSettingsDivider(accent: accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Asked by \(request.requester)")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                    if let reason = request.reason, !reason.isEmpty {
                        Text("\u{201C}\(reason)\u{201D}")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    expiryText(request)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        approveButton(request, busy: busy)
                        declineButton(request, busy: busy)
                    }
                    VStack(spacing: 10) {
                        approveButton(request, busy: busy)
                        declineButton(request, busy: busy)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-approval-\(request.requestId)")
    }

    private func changeBlock(_ change: SettingsApprovalRequest.Change, accent: Color) -> some View {
        let qualifiers = change.qualifiers?
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            TronSettingsRow(
                icon: nil,
                title: change.label,
                subtitle: qualifiers?.isEmpty == false ? qualifiers : nil,
                accent: accent
            )
            VStack(alignment: .leading, spacing: 6) {
                if change.redacted == true {
                    Text("New value hidden")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                } else if let display = change.display {
                    Text("\(display.before) → \(display.after)")
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.layerLabel(change.layer))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                if let confirm = change.confirm {
                    Text(confirm)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if change.redacted != true {
                    // The maintainer's view of the exact values when display strings abbreviate them.
                    TronTechnicalJSONRow(
                        value: .object(["before": change.before ?? .null, "after": change.after ?? .null]),
                        title: "Exact values",
                        subtitle: "The values approval applies",
                        sheetTitle: change.label,
                        accent: .tronSlate
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func expiryText(_ request: SettingsApprovalRequest) -> some View {
        if let date = request.expiryDate {
            Text("Expires \(date, format: .relative(presentation: .named))")
        } else {
            Text("Expires \(request.expiresAt)")
        }
    }

    private func approveButton(_ request: SettingsApprovalRequest, busy: Bool) -> some View {
        Button {
            decide(request, approved: true)
        } label: {
            Text("Approve")
        }
        .buttonStyle(TronActionButtonStyle(role: .primary, accent: .tronSuccess))
        .disabled(busy)
        .accessibilityIdentifier("settings-approval-approve-\(request.requestId)")
    }

    private func declineButton(_ request: SettingsApprovalRequest, busy: Bool) -> some View {
        Button(role: .destructive) {
            decide(request, approved: false)
        } label: {
            Text("Decline")
        }
        .buttonStyle(TronActionButtonStyle(role: .destructive, accent: .tronError))
        .disabled(busy)
        .accessibilityIdentifier("settings-approval-decline-\(request.requestId)")
    }

    private static func layerLabel(_ layer: String) -> String {
        switch layer {
        case "mac": "Mac"
        case "chat": "Chat"
        case "project": "Project"
        case "profile": "Profile: Home"
        default: layer.capitalized
        }
    }

    private func load() async {
        let foreground = model.foregroundReconciliationGeneration
        let identity = model.knowledgePresentationIdentity
        let activity = presentationActivity
        guard activity.allowsPresentationPublication, !Task.isCancelled else { return }
        // Event reads share this lane; a superseded read is discarded by its ticket.
        loadGeneration &+= 1
        let ticket = loadGeneration
        do {
            let value = try await model.settingsApprovals(scope: scope)
            guard ticket == loadGeneration, !Task.isCancelled,
                  identity == model.knowledgePresentationIdentity,
                  foreground == model.foregroundReconciliationGeneration,
                  activity == presentationActivity, activity.allowsPresentationPublication else { return }
            // Gateway timestamps share one ISO-8601 format, so text order is time order.
            requests = value.sorted { $0.createdAt > $1.createdAt }
            claimStagedSettingsDecision()
        } catch is CancellationError {
            return
        } catch {
            guard ticket == loadGeneration, !Task.isCancelled,
                  identity == model.knowledgePresentationIdentity,
                  foreground == model.foregroundReconciliationGeneration,
                  activity == presentationActivity, activity.allowsPresentationPublication else { return }
            requests = []
        }
    }

    /// Gateway text only, in the row's own order: who asked, each change's exact display
    /// and its confirm text. The decision still binds to the raw values.
    private static func confirmationMessage(_ request: SettingsApprovalRequest) -> String {
        let labels = request.changes.map(\.label).joined(separator: ", ")
        var message = "\(request.requester) asks to change \(labels)."
        for change in request.changes where change.redacted != true {
            if let display = change.display {
                message += " \(change.label): \(display.before) → \(display.after)."
            }
        }
        for change in request.changes {
            if let confirm = change.confirm { message += " \(confirm)" }
        }
        return message
    }

    /// A push names only the session that asked, not the request or its digest, and a
    /// newer request may have superseded the one it described. So the action is staged as
    /// a confirmation over that session's row, and nothing is decided until the maintainer taps.
    private func claimStagedSettingsDecision() {
        guard let staged = model.freshStagedSettingsDecision() else { return }
        let candidates = requests.filter { $0.actor.sessionId == staged.sessionID }
        let belongsHere = !candidates.isEmpty
            || scope == .session(staged.sessionID)
            || (scope == .home && staged.sessionID == model.homeStatus.status?.sessionId)
        guard belongsHere else { return }
        model.consumeStagedSettingsDecision(staged.id)
        switch candidates.count {
        case 1:
            confirmation = PendingSettingsDecision(request: candidates[0], approved: staged.decision == .approve)
            confirmationPresented = true
        case 0:
            noLongerWaiting = true
        default:
            // Several requests from one session: the rows stay on screen for the maintainer to choose.
            break
        }
    }

    private func decide(_ request: SettingsApprovalRequest, approved: Bool) {
        guard presentationActivity.allowsPresentationPublication,
              !deciding.contains(request.requestId) else { return }
        deciding.insert(request.requestId)
        let requestIdentity = model.knowledgePresentationIdentity
        // The decision is a mutation: unstructured so the view cannot cancel it mid-flight.
        Task { @MainActor in
            do {
                try await model.decideSettingsApproval(request, approved: approved)
            } catch is CancellationError {
                // Nothing to present; the reload below reflects the authoritative state.
            } catch {
                if presentationActivity.allowsPresentationPublication,
                   model.knowledgePresentationIdentity == requestIdentity {
                    model.presentError(error)
                }
            }
            // Keep the card disabled until the reload shows the decided state.
            await load()
            deciding.remove(request.requestId)
        }
    }
}

import SwiftUI

struct ProjectTrustSummary: Equatable, Sendable {
    let cwd: String
    let requiresDecision: Bool
    let savedDecision: Bool?
    let defaultDecision: String
    let effectiveDecision: Bool?

    init(_ value: JSONValue?) {
        let object = value?.objectValue ?? [:]
        cwd = object["cwd"]?.stringValue ?? "Unknown workspace"
        requiresDecision = object["requiresDecision"]?.boolValue ?? false
        savedDecision = object["savedDecision"]?.boolValue
        defaultDecision = object["defaultDecision"]?.stringValue ?? "ask"
        effectiveDecision = object["effectiveDecision"]?.boolValue
    }

    var stateTitle: String {
        switch effectiveDecision {
        case true: "Trusted"
        case false: "Resources blocked"
        case nil: requiresDecision ? "Decision needed" : "No decision required"
        }
    }

    var stateDetail: String {
        switch effectiveDecision {
        case true: "Project resources may load with your Mac user authority."
        case false: "Project-local resources will not be loaded."
        case nil: requiresDecision
            ? "Choose whether this workspace may load project-local resources."
            : "This workspace does not currently require a trust decision."
        }
    }

    var stateIcon: String {
        switch effectiveDecision {
        case true: "checkmark.shield.fill"
        case false: "nosign"
        case nil: requiresDecision ? "questionmark.circle.fill" : "info.circle.fill"
        }
    }

    var defaultDecisionLabel: String { defaultDecision.capitalized }
    var savedDecisionLabel: String { savedDecision.map { $0 ? "Trusted" : "Blocked" } ?? "Not saved" }
}

struct TrustSettingsView: View {
    @Environment(AppModel.self) private var model
    let target: TrustTarget?
    @State private var inspection: JSONValue?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 16) {
                if target != nil {
                    if let inspection {
                        let summary = ProjectTrustSummary(inspection)
                        trustSummaryCard(summary)
                        decisionSection(summary)
                        TronTechnicalJSONRow(
                            value: inspection,
                            title: "Trust Record",
                            subtitle: "View full protocol representation",
                            sheetTitle: "Project Trust JSON",
                            accent: .tronSlate
                        )
                    } else {
                        TronLoadingState(label: "Loading project trust…", accent: .tronAmber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    informationalCard(
                        title: "No workspace selected",
                        detail: "Open a session to inspect its project trust.",
                        icon: "folder.badge.questionmark",
                        accent: .tronSlate
                    )
                }

                TronInfoCard(
                    icon: "exclamationmark.shield",
                    text: "Trust gates project-local settings, extensions, skills, prompts, packages, and system prompt files. It is not a sandbox.",
                    accent: .tronAmber
                )
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project Trust")
        .task(id: TrustLoadID(target: target, invalidationGeneration: model.trustRevision)) { await load() }
    }

    private func trustSummaryCard(_ summary: ProjectTrustSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summary.stateIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(summary.effectiveDecision == false ? Color.tronError : Color.tronAmber)
                    .frame(width: 38, height: 38)
                    .background(
                        (summary.effectiveDecision == false ? Color.tronError : Color.tronAmber).opacity(0.12),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.stateTitle)
                        .font(TronTypography.headline)
                        .foregroundStyle(Color.tronTextPrimary)
                    Text(summary.stateDetail)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            Divider().overlay(Color.tronAmber.opacity(0.18))
            trustMetadataRow("Workspace", summary.cwd)
            trustMetadataRow("Default policy", summary.defaultDecisionLabel)
            trustMetadataRow("Saved decision", summary.savedDecisionLabel)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
    }

    private func trustMetadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(TronTypography.code(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func decisionSection(_ summary: ProjectTrustSummary) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text("Decision")
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Controls whether project-local resources may load.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
            }

            VStack(spacing: 10) {
                if summary.effectiveDecision != true {
                    Button("Trust Project", systemImage: "checkmark.shield") { update(true) }
                        .buttonStyle(TronActionButtonStyle(role: .primary))
                }
                if summary.effectiveDecision != false {
                    Button("Do Not Load Project Resources", systemImage: "nosign", role: .destructive) { update(false) }
                        .buttonStyle(TronActionButtonStyle(role: .destructive))
                }
                if summary.savedDecision != nil {
                    Button("Clear Saved Decision", systemImage: "arrow.counterclockwise") { update(nil) }
                        .buttonStyle(TronActionButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func informationalCard(title: String, detail: String, icon: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TronTypography.headline)
                Text(detail)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: accent, tintOpacity: 0.08)
    }

    private func load() async {
        guard let target else { return }
        do {
            let value = try await model.inspectTrust(target: target)
            guard target == self.target else { return }
            inspection = value
        } catch is CancellationError {
            return
        } catch {
            guard target == self.target else { return }
            model.presentError(error)
        }
    }

    private func update(_ decision: Bool?) {
        guard let target else { return }
        Task {
            do {
                let value = try await model.setTrust(target: target, decision: decision)
                guard target == self.target else { return }
                inspection = value
            } catch {
                guard target == self.target else { return }
                model.presentError(error)
            }
        }
    }
}

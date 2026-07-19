import SwiftUI

/// Compact, read-only presentation of Tron's current session-level workflows.
///
/// This surface intentionally names the three product concepts directly. It
/// is not a generic workflow renderer, and it does not infer state from lower-
/// level capability invocations.
struct SessionWorkflowSummaryCard: View {
    let snapshot: SessionWorkflowSnapshotV1
    let onContextRevisionTap: () -> Void

    private var presentation: SessionWorkflowSummaryPresentation {
        SessionWorkflowSummaryPresentation(snapshot: snapshot)
    }

    var body: some View {
        if presentation.hasContent {
            VStack(alignment: .leading, spacing: 10) {
                Text("Session activity")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)

                if let contextRevision = presentation.contextRevision {
                    Button(action: onContextRevisionTap) {
                        summaryRow(contextRevision)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session-workflow-context-revision")
                }

                if let branch = presentation.branch {
                    summaryRow(branch)
                        .accessibilityIdentifier("session-workflow-branch-lineage")
                }

                if let delegation = presentation.delegation {
                    summaryRow(delegation)
                        .accessibilityIdentifier("session-workflow-delegations")
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.tronEmerald.opacity(0.14), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session-workflow-summary")
        }
    }

    private func summaryRow(_ item: SessionWorkflowSummaryPresentation.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                if let detail = item.detail {
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct SessionWorkflowSummaryPresentation: Equatable {
    struct Item: Equatable {
        let title: String
        let detail: String?
        let icon: String
        let tint: Color

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title
                && lhs.detail == rhs.detail
                && lhs.icon == rhs.icon
                && lhs.tint == rhs.tint
        }
    }

    let contextRevision: Item?
    let branch: Item?
    let delegation: Item?

    var hasContent: Bool {
        contextRevision != nil || branch != nil || delegation != nil
    }

    init(snapshot: SessionWorkflowSnapshotV1) {
        contextRevision = Self.contextRevisionItem(snapshot.contextRevision)
        branch = snapshot.branchLineage.isBranch
            ? Item(
                title: "Branch session",
                detail: "Continues from an earlier point without changing the original session.",
                icon: "arrow.triangle.branch",
                tint: .tronSky
            )
            : nil
        delegation = Self.delegationItem(
            active: snapshot.activeDelegations,
            recent: snapshot.recentDelegations,
            truncated: snapshot.truncated
        )
    }

    private static func contextRevisionItem(_ revision: ContextRevisionSnapshotV1?) -> Item? {
        guard let revision else { return nil }
        let title = switch revision.state {
        case "succeeded": switch revision.kind {
            case "compact": "Context compacted"
            case "clear": "Context cleared"
            default: "Context revised"
            }
        case "requested": "Revising context"
        case "skipped": "Context revision skipped"
        case "failed": "Context revision failed"
        default: "Context revision"
        }
        let detail = normalized(revision.reason) ?? readableState(revision.state)
        return Item(
            title: title,
            detail: detail,
            icon: revision.kind == "clear" ? "xmark.circle" : "arrow.triangle.2.circlepath",
            tint: revision.kind == "clear" ? .tronError : .tronEmerald
        )
    }

    private static func delegationItem(
        active: [DelegationSnapshotV1],
        recent: [DelegationSnapshotV1],
        truncated: Bool
    ) -> Item? {
        if !active.isEmpty {
            let noun = active.count == 1 ? "delegation" : "delegations"
            return Item(
                title: "\(active.count) active \(noun)",
                detail: delegationDetail(
                    normalized(active.first?.objectiveSummary),
                    truncated: truncated
                ),
                icon: "person.2.fill",
                tint: .tronPurple
            )
        }
        guard !recent.isEmpty else { return nil }
        let latest = recent[0]
        let title = switch latest.state {
        case "result_ready": "Delegation result ready"
        case "accepted": "Delegation result accepted"
        case "failed": "Delegation failed"
        case "cancelled": "Delegation cancelled"
        default: "Delegation updated"
        }
        return Item(
            title: title,
            detail: delegationDetail(
                normalized(latest.resultSummary) ?? normalized(latest.objectiveSummary),
                truncated: truncated
            ),
            icon: "person.2",
            tint: .tronPurple
        )
    }

    private static func delegationDetail(_ summary: String?, truncated: Bool) -> String? {
        guard truncated else { return summary }
        if let summary {
            return "\(summary) · More delegation history exists"
        }
        return "More delegation history exists"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func readableState(_ state: String) -> String? {
        let readable = state.replacingOccurrences(of: "_", with: " ")
        return readable.isEmpty ? nil : readable.prefix(1).uppercased() + readable.dropFirst()
    }
}

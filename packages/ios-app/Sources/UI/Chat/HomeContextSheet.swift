import SwiftUI
import TronMobileCore

/// Home Context: where the last activation's request context went, as one summary
/// card with a section-segmented bar and a compact legend. With no breakdown (an older
/// Gateway) it shows the plain request sizes, without any raw identifiers.
extension HomeSheet {
    @ViewBuilder func contextSheet(_ context: HomeContextDTO) -> some View {
        if let breakdown = context.breakdown {
            breakdownView(breakdown)
        } else if context.activation.available {
            plainContext(context.activation)
        } else {
            TronPlaceholderState(title: "No activation context yet", detail: "Home has not prepared a response.",
                                 icon: "doc.text.magnifyingglass")
        }
    }

    /// One summary card: the activation as its header, the window split by section
    /// with a compact legend, then the Home chat's cache, input and output metrics.
    @ViewBuilder private func breakdownView(_ breakdown: HomeContextDTO.Breakdown) -> some View {
        let segments = SessionContextSegments(
            used: breakdown.effectiveTokens, window: breakdown.contextWindow,
            segments: breakdown.sections.map { section in
                .init(id: section.id.rawValue,
                      label: HomeContextPresentation.sectionLabel(section.id, input: breakdown.activation.kind),
                      tokens: section.tokens, color: Self.sectionColor(section.id),
                      detail: HomeContextPresentation.countLine(section))
            })
        let header = HStack(spacing: 8) {
            TronStatusPill(text: breakdown.activation.state == .running ? "Running" : "Settled",
                           accent: breakdown.activation.state == .running ? .tronEmerald : .tronSlate)
            Text(HomeContextPresentation.activationLine(breakdown.activation))
                .font(SessionSummaryTypography.detail)
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-context-activation")
        Group {
            if let sessionID, let snapshot = model.sessionContextPresentation(for: sessionID) {
                SessionContextUsageCard(snapshot: snapshot, accessory: header, segments: segments)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    header
                    SessionContextSegmentedBar(segments: segments)
                    SessionContextSegmentLegend(segments: segments)
                }
                .padding(14)
                .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-context-breakdown")
    }

    /// The plain request sizes an older Gateway reports, in the rows' style.
    private func plainContext(_ activation: HomeStatusDTO.Activation) -> some View {
        TronGlassCard(accent: .tronSessionTeal) {
            VStack(spacing: 0) {
                TronValueRow(icon: "bolt", title: "Activation", value: activation.activationOpen == true ? "Open" : "Settled")
                TronSettingsDivider(accent: .tronSessionTeal)
                TronValueRow(icon: "text.alignleft", title: "Effective context",
                             value: activation.effectiveTokens.map { "\($0.formatted()) tokens" } ?? "Not prepared")
                TronSettingsDivider(accent: .tronSessionTeal)
                TronValueRow(icon: "rectangle.compress.vertical", title: "Context window",
                             value: activation.contextWindow.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                if let lines = activation.viewLines {
                    TronSettingsDivider(accent: .tronSessionTeal)
                    TronValueRow(icon: "brain", title: "Memory view", value: "\(lines.formatted()) lines")
                }
                if let reason = activation.lastRefusalReason {
                    TronSettingsDivider(accent: .tronSessionTeal)
                    TronValueRow(icon: "exclamationmark.triangle", title: "Refused", value: reason)
                }
            }
        }
    }

    static func sectionColor(_ id: HomeContextDTO.Breakdown.Section.ID) -> Color {
        switch id {
        case .instructions: .tronSlate
        case .profile: .tronPurple
        case .memory: .tronKnowledge
        case .chapter: .tronSessionTeal
        case .results: .tronSuccess
        case .input: .tronBlue
        }
    }
}

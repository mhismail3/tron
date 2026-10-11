import SwiftUI
import TronMobileCore

/// Home Context: where the last activation's request context went, as one bar of
/// the context window and a meaning per section. With no breakdown (an older
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

    private func breakdownView(_ breakdown: HomeContextDTO.Breakdown) -> some View {
        let free = max(0, breakdown.contextWindow - breakdown.effectiveTokens)
        return VStack(alignment: .leading, spacing: 14) {
            Text(HomeContextPresentation.activationLine(breakdown.activation))
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
                .accessibilityIdentifier("home-context-activation")
            contextBar(breakdown)
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(spacing: 0) {
                    ForEach(Array(breakdown.sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                        legendRow(section, input: breakdown.activation.kind)
                    }
                    TronSettingsDivider(accent: .tronSessionTeal)
                    freeRow(free)
                }
            }
            .accessibilityIdentifier("home-context-breakdown")
        }
    }

    /// One bar of the context window: each section's share in order, and the free
    /// remainder left as the track.
    private func contextBar(_ breakdown: HomeContextDTO.Breakdown) -> some View {
        let window = CGFloat(max(breakdown.contextWindow, 1))
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(breakdown.sections) { section in
                    Rectangle()
                        .fill(Self.sectionColor(section.id))
                        .frame(width: geometry.size.width * min(1, CGFloat(section.tokens) / window))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(Capsule().fill(Color.tronSlate.opacity(0.14)))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window: \(breakdown.effectiveTokens.formatted()) of \(breakdown.contextWindow.formatted()) tokens")
        .accessibilityIdentifier("home-context-bar")
    }

    private func legendRow(_ section: HomeContextDTO.Breakdown.Section, input: HomeContextDTO.Breakdown.Activation.Kind) -> some View {
        let label = HomeContextPresentation.sectionLabel(section.id, input: input)
        let meaning = HomeContextPresentation.meaning(section.id, input: input)
        let count = HomeContextPresentation.countLine(section)
        let tokens = section.tokens.formatted(.number.notation(.compactName))
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Self.sectionColor(section.id))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text([meaning, count].compactMap { $0 }.joined(separator: " · "))
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(tokens)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([label, count, "\(section.tokens.formatted()) tokens"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("home-context-section-\(section.id.rawValue)")
    }

    private func freeRow(_ free: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .stroke(Color.tronSlate.opacity(0.6), lineWidth: 1)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Free")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text("Room left in the context window")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            Spacer(minLength: 8)
            Text(free.formatted(.number.notation(.compactName)))
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

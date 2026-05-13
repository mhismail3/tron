import SwiftUI

// MARK: - Capabilities Section (standalone container with badge - clay/ochre)

@available(iOS 26.0, *)
struct CapabilitiesSection: View {
    let capabilitiesContent: [CapabilitySummaryInfo]
    let tokens: Int
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: ContextLayout.iconTextSpacing) {
                Image(systemName: "hammer.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronSlate)
                    .frame(width: ContextLayout.iconFrameWidth)
                Text("Capabilities")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronSlate)

                Text("\(capabilitiesContent.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronSlate)

                Spacer()
                Text(TokenFormatter.format(tokens))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(ContextLayout.rowInnerPadding)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                CapabilityGrid(capabilities: capabilitiesContent)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronSlate, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Capability Grid (3-column compact layout)

@available(iOS 26.0, *)
struct CapabilityGrid: View {
    let capabilities: [CapabilitySummaryInfo]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(capabilities) { capability in
                CapabilityGridItem(capability: capability)
            }
        }
    }
}

@available(iOS 26.0, *)
struct CapabilityGridItem: View {
    let capability: CapabilitySummaryInfo

    private var identity: CapabilityIdentity {
        CapabilityIdentity(
            modelPrimitiveName: capability.name,
            contractId: capability.name.contains("::") ? capability.name : nil,
            implementationId: nil,
            functionId: capability.name.contains("::") ? capability.name : nil,
            pluginId: nil,
            workerId: nil,
            schemaDigest: nil,
            catalogRevision: nil,
            trustTier: nil,
            riskLevel: nil,
            effectClass: nil,
            traceId: nil,
            rootInvocationId: nil,
            bindingDecisionId: nil
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: CapabilityPresentation.symbol(for: identity))
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(CapabilityPresentation.color(for: identity))
                .frame(width: 14)
            Text(capability.name)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronSlate, cornerRadius: 6, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

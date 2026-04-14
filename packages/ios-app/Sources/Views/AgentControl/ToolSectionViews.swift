import SwiftUI

// MARK: - Tools Section (standalone container with badge - clay/ochre)

@available(iOS 26.0, *)
struct ToolsSection: View {
    let toolsContent: [ToolSummaryInfo]
    let tokens: Int
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronSlate)
                    .frame(width: 18)
                Text("Tools")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronSlate)

                Text("\(toolsContent.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronSlate)

                Spacer()
                Text(TokenFormatter.format(tokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                ToolGrid(tools: toolsContent)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronSlate, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tool Grid (3-column compact layout)

@available(iOS 26.0, *)
struct ToolGrid: View {
    let tools: [ToolSummaryInfo]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(tools) { tool in
                ToolGridItem(tool: tool)
            }
        }
    }
}

@available(iOS 26.0, *)
struct ToolGridItem: View {
    let tool: ToolSummaryInfo

    private var descriptor: ToolDescriptor {
        ToolRegistry.descriptor(for: tool.name)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: descriptor.icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(descriptor.iconColor)
                .frame(width: 14)
            Text(tool.name)
                .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
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


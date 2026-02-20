import SwiftUI

// MARK: - Tools Section (standalone container with badge - clay/ochre)

@available(iOS 26.0, *)
struct ToolsSection: View {
    let toolsContent: [String]
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
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(toolsContent.enumerated()), id: \.offset) { _, tool in
                        ToolItemRow(tool: tool)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronSlate)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tool Item Row

@available(iOS 26.0, *)
struct ToolItemRow: View {
    let tool: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.fill")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronSlate)

            Text(tool)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronSlate)

            Spacer()
        }
        .padding(8)
        .sectionFill(.tronSlate, cornerRadius: 6, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Expandable Content Section

@available(iOS 26.0, *)
struct ExpandableContentSection: View {
    let icon: String
    let iconColor: Color
    let title: String
    let tokens: Int
    let content: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(iconColor.opacity(0.8))
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(TokenFormatter.format(tokens))
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                ScrollView {
                    ContextMarkdownContent(content: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .sectionFill(iconColor, cornerRadius: 6, subtle: true)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .sectionFill(iconColor, cornerRadius: 8)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

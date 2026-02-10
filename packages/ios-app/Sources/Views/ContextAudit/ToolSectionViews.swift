import SwiftUI

// MARK: - Tools Section (standalone container with badge - clay/ochre)

@available(iOS 26.0, *)
struct ToolsSection: View {
    let toolsContent: [String]
    let tokens: Int
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header - using onTapGesture to avoid any button highlight behavior
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronClay)
                    .frame(width: 18)
                Text("Tools")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronClay)

                // Count badge
                Text("\(toolsContent.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronClay)

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

            // Content
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(toolsContent.enumerated()), id: \.offset) { index, tool in
                            ToolItemView(tool: tool)
                            if index < toolsContent.count - 1 {
                                Divider()
                                    .background(Color.tronOverlay(0.1))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
                .sectionFill(.tronClay, cornerRadius: 6, subtle: true)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronClay)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tool Item View

@available(iOS 26.0, *)
struct ToolItemView: View {
    let tool: String

    private var toolName: String {
        if let colonIndex = tool.firstIndex(of: ":") {
            return String(tool[..<colonIndex])
        }
        return tool
    }

    private var toolDescription: String {
        if let colonIndex = tool.firstIndex(of: ":") {
            let afterColon = tool.index(after: colonIndex)
            return String(tool[afterColon...]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(toolName)
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(.tronClay)
                .lineLimit(2)
            if !toolDescription.isEmpty {
                Text(toolDescription)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
                    Text(content)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
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

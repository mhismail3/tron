import SwiftUI

// MARK: - System Prompt Section (standalone container)

@available(iOS 26.0, *)
struct SystemPromptSection: View {
    let tokens: Int
    let content: String
    var environment: EnvironmentInfo?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronPurple)
                    .frame(width: 18)
                Text("System Prompt")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronPurple)
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
                VStack(alignment: .leading, spacing: 6) {
                    // Environment sub-containers
                    if let env = environment {
                        if let wd = env.workingDirectory {
                            EnvironmentItemRow(icon: "folder", label: "Working Directory", value: wd)
                        }
                        if let origin = env.serverOrigin {
                            EnvironmentItemRow(icon: "server.rack", label: "Server Origin", value: origin)
                        }
                    }

                    // Full prompt content
                    ScrollView {
                        ContextMarkdownContent(content: content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                    .sectionFill(.tronPurple, cornerRadius: 6, subtle: true)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronPurple)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Environment Item Row

@available(iOS 26.0, *)
struct EnvironmentItemRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronPurple)

            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronPurple)

            Spacer()

            Text(value)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .sectionFill(.tronPurple, cornerRadius: 6, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

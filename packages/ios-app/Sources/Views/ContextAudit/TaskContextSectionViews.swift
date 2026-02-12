import SwiftUI

// MARK: - Task Context Section (expandable, shows task summary injected into LLM context)

@available(iOS 26.0, *)
struct TaskContextSection: View {
    let taskContext: LoadedTaskContext
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                Text("Tasks")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.orange)

                Spacer()

                Text(TokenFormatter.format(taskContext.tokens))
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

            // Expandable content
            if isExpanded {
                ScrollView {
                    ContextMarkdownContent(content: taskContext.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .sectionFill(.orange, cornerRadius: 6, subtle: true)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.orange)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

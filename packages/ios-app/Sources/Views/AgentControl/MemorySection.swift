import SwiftUI

// MARK: - Memory Section (standalone container)
//
// Renders the user-memory snapshot loaded from ~/.tron/memory/
// MEMORY.md plus the listing of rules/*.md detail files. Positioned under
// the "System Instructions" section in the Agent Control context sheet.
//
// Wire data: `UserMemorySnapshot` decoded from `context.get_detailed_snapshot`
// response. Server-side loader: `runtime::memory::MemoryRegistry`.
//
// UX shape:
// - Collapsed: header row (icon + "Memory" label + token count + chevron +
//   a small "bootstrapped" vs "empty" indicator).
// - Expanded: MEMORY.md content rendered as markdown + a list of rules/ files
//   with their frontmatter descriptions (names only — contents are not
//   pre-loaded; agent reads on demand via the `Read` capability).

@available(iOS 26.0, *)
struct MemorySection: View {
    let tokens: Int
    let memory: UserMemorySnapshot
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                expandedContent
            }
        }
        .sectionFill(.tronSlate, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ContextLayout.iconTextSpacing) {
            Image(systemName: "brain.head.profile")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronSlate)
                .frame(width: ContextLayout.iconFrameWidth)
            Text("Memory")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronSlate)
            if !memory.bootstrapped {
                Text("empty")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.tronSlate.opacity(0.12))
                    )
            }
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
    }

    // MARK: - Expanded content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MEMORY.md body (always non-empty — either the real content or
            // the server-generated bootstrap stub).
            ScrollView {
                ContextMarkdownContent(content: memory.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 300)
            .sectionFill(.tronSlate, cornerRadius: 6, subtle: true, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Rules files listing (names + descriptions only; contents read on demand).
            if !memory.ruleFiles.isEmpty {
                ruleFilesListing
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var ruleFilesListing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detail files")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(memory.ruleFiles) { file in
                    ruleFileRow(file)
                }
            }
        }
    }

    private func ruleFileRow(_ file: UserMemoryRuleFile) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("rules/\(file.name)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
                if let description = file.description, !description.isEmpty {
                    Text(description)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sectionFill(.tronSlate, cornerRadius: 6, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

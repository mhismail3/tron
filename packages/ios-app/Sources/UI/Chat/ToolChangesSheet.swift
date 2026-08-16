import SwiftUI

struct ToolChangesSheet: View {
    let diff: ToolDiffPresentation
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ToolChipFlowLayout(spacing: 7) {
                        if let count = diff.requestedChangeCount {
                            ToolStaticChip(
                                icon: "pencil",
                                text: "\(count) \(count == 1 ? "change" : "changes")",
                                accent: accent
                            )
                        }
                        if let count = diff.diffUnitCount {
                            ToolStaticChip(
                                icon: "rectangle.stack",
                                text: "\(count) diff \(count == 1 ? "section" : "sections")",
                                accent: .tronBlue
                            )
                        }
                    }
                    ToolDiffView(lines: diff.lines)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Changes", accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

struct ToolDiffView: View {
    let lines: [ToolDiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker(for: line.kind))
                            .font(TronFont.mono(11, weight: .bold))
                            .foregroundStyle(foreground(for: line.kind))
                            .frame(width: 15, alignment: .center)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(foreground(for: line.kind))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, verticalPadding(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line.kind))
                }
            }
            .padding(.vertical, 7)
        }
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07)
        .accessibilityLabel("File changes")
    }

    private func marker(for kind: ToolDiffLineKind) -> String {
        switch kind {
        case .addition: "+"
        case .removal: "−"
        case .hunk: "•"
        case .omitted: "…"
        case .context, .metadata: " "
        }
    }

    private func foreground(for kind: ToolDiffLineKind) -> Color {
        switch kind {
        case .addition: .tronEmerald
        case .removal: .tronError
        case .hunk: .tronBlue
        case .omitted: .tronAmber
        case .metadata: .tronTextMuted
        case .context: .tronTextSecondary
        }
    }

    private func background(for kind: ToolDiffLineKind) -> Color {
        switch kind {
        case .addition: .tronEmerald.opacity(0.10)
        case .removal: .tronError.opacity(0.10)
        case .hunk: .tronBlue.opacity(0.08)
        case .omitted: .tronAmber.opacity(0.08)
        case .context, .metadata: .clear
        }
    }

    private func verticalPadding(for kind: ToolDiffLineKind) -> CGFloat {
        switch kind {
        case .hunk, .omitted: 6
        default: 2
        }
    }
}

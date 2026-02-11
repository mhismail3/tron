import SwiftUI

// MARK: - Memory Section (expandable, shows auto-injected memory entries)

@available(iOS 26.0, *)
struct MemorySection: View {
    let memory: LoadedMemory
    @State private var isExpanded = false

    private var entries: [LoadedMemoryEntry] { memory.entries ?? [] }
    private var hasEntries: Bool { !entries.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable when entries exist)
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.purple)
                    .frame(width: 18)
                Text("Memories")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.purple)

                // Count badge
                Text("\(memory.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.purple)

                Spacer()

                Text(TokenFormatter.format(memory.tokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                if hasEntries {
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                guard hasEntries else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expandable content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        MemoryEntryRow(entry: entry)
                    }
                }
                .padding(10)
            }
        }
        .sectionFill(.purple)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Session Memories Section (memories written during this session)

@available(iOS 26.0, *)
struct SessionMemoriesSection: View {
    let memory: LoadedMemory
    @State private var isExpanded = false

    private var entries: [LoadedMemoryEntry] { memory.entries ?? [] }
    private var hasEntries: Bool { !entries.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.purple)
                    .frame(width: 18)
                Text("New Memories")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.purple)

                Text("\(memory.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.purple)

                Spacer()

                Text(TokenFormatter.format(memory.tokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                if hasEntries {
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                guard hasEntries else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        MemoryEntryRow(entry: entry)
                    }
                }
                .padding(10)
            }
        }
        .sectionFill(.purple)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Memory Entry Row (expandable to view content)

@available(iOS 26.0, *)
struct MemoryEntryRow: View {
    let entry: LoadedMemoryEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (tappable)
            HStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.purple.opacity(0.8))
                    .frame(width: 20)

                Text(entry.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.tronTextDisabled)
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

            // Expanded content
            if isExpanded {
                if !entry.content.isEmpty {
                    ScrollView {
                        ContextMarkdownContent(content: entry.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                    .sectionFill(.purple, cornerRadius: 6, subtle: true)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                } else {
                    Text("No details recorded")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .sectionFill(.purple, cornerRadius: 8, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

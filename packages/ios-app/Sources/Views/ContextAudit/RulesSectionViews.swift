import SwiftUI

// MARK: - Rules Section (immutable, cannot be removed)

@available(iOS 26.0, *)
struct RulesSection: View {
    let rules: LoadedRules
    var onFetchContent: ((String) async throws -> String)?
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header row (tappable)
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTerracotta)
                    .frame(width: 18)
                Text("Rules")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTerracotta)

                // Count badge
                Text("\(rules.totalFiles)")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronTerracotta.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text(TokenFormatter.format(rules.tokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rules.files) { file in
                        RulesFileRow(
                            file: file,
                            onFetchContent: onFetchContent
                        )
                    }
                }
                .padding(10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronTerracotta.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Rules File Row (expandable to view content)

@available(iOS 26.0, *)
struct RulesFileRow: View {
    let file: RulesFile
    var content: String?
    var onFetchContent: ((String) async throws -> String)?

    @State private var isExpanded = false
    @State private var loadedContent: String?
    @State private var isLoadingContent = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row (tappable)
            HStack(spacing: 10) {
                Image(systemName: file.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTerracotta.opacity(0.8))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayPath)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    Text(file.label)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                // Fetch content on first expand if not already loaded
                if isExpanded && loadedContent == nil && !isLoadingContent {
                    Task {
                        await fetchContent()
                    }
                }
            }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoadingContent {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.tronTerracotta)
                            Text("Loading content...")
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronError)
                                Text("Failed to load content")
                                    .font(TronTypography.codeSM)
                                    .foregroundStyle(.tronError)
                            }
                            Text(error)
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.4))
                            Text("Path: \(file.path)")
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.3))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.tronError.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else if let displayContent = loadedContent ?? content {
                        ScrollView {
                            Text(displayContent)
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Text("Content not available")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.tronTerracotta.opacity(0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // NO context menu - rules cannot be deleted
    }

    private func fetchContent() async {
        isLoadingContent = true
        loadError = nil
        if let fetch = onFetchContent {
            do {
                loadedContent = try await fetch(file.path)
            } catch {
                loadError = error.localizedDescription
            }
        }
        isLoadingContent = false
    }
}

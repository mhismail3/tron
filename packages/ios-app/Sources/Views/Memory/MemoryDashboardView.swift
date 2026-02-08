import SwiftUI

@available(iOS 26.0, *)
struct MemoryDashboardView: View {
    let rpcClient: RPCClient
    let workingDirectory: String
    let onSettings: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?

    @State private var entries: [LedgerEntryDTO] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMore = false
    @State private var totalCount = 0
    @State private var errorMessage: String?
    @State private var selectedEntry: LedgerEntryDTO?
    @State private var showingTagFilter = false
    @State private var selectedTags: Set<String> = []

    private let pageSize = 30

    private var allTags: [String] {
        let tagSet = Set(entries.flatMap(\.tags))
        return tagSet.sorted()
    }

    private var filteredEntries: [LedgerEntryDTO] {
        if selectedTags.isEmpty { return entries }
        return entries.filter { entry in
            entry.tags.contains(where: { selectedTags.contains($0) })
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isLoading && entries.isEmpty {
                ProgressView()
                    .tint(.purple)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                errorView(error)
            } else if entries.isEmpty {
                emptyView
            } else {
                entryList
            }

            // Floating filter button
            if !allTags.isEmpty {
                filterButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(NavigationMode.allCases, id: \.self) { mode in
                        Button {
                            onNavigationModeChange?(mode)
                        } label: {
                            Label(mode.rawValue, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image("TronLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("MEMORY")
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.purple)
                    .tracking(2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.purple)
                }
            }
        }
        .sheet(item: $selectedEntry) { entry in
            MemoryDashboardDetailSheet(entry: entry)
        }
        .sheet(isPresented: $showingTagFilter) {
            TagFilterSheet(
                allTags: allTags,
                selectedTags: $selectedTags
            )
        }
        .task {
            await loadEntries()
        }
        .refreshable {
            entries = []
            await loadEntries()
        }
    }

    // MARK: - Entry List

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredEntries) { entry in
                    LedgerEntryRow(entry: entry)
                        .onTapGesture {
                            selectedEntry = entry
                        }
                        .onAppear {
                            if entry.id == entries.last?.id && hasMore {
                                Task { await loadMore() }
                            }
                        }
                }

                if isLoadingMore {
                    ProgressView()
                        .tint(.purple)
                        .padding()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Filter Button

    private var filterButton: some View {
        Button {
            showingTagFilter = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                if !selectedTags.isEmpty {
                    Text("\(selectedTags.count)")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .bold))
                }
            }
            .foregroundStyle(.purple)
            .frame(height: 48)
            .padding(.horizontal, selectedTags.isEmpty ? 12 : 16)
            .contentShape(selectedTags.isEmpty ? AnyShape(Circle()) : AnyShape(Capsule()))
        }
        .glassEffect(
            .regular.tint(Color.purple.opacity(0.4)).interactive(),
            in: selectedTags.isEmpty ? AnyShape(Circle()) : AnyShape(Capsule())
        )
    }

    // MARK: - Empty & Error States

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.fill")
                .font(TronTypography.sans(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Memory Entries")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Ledger entries will appear here as sessions complete")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(TronTypography.sans(size: 40))
                .foregroundStyle(.red)

            Text(error)
                .font(TronTypography.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await loadEntries() }
            }
            .foregroundStyle(.purple)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadEntries() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await rpcClient.misc.getLedgerEntries(
                workingDirectory: workingDirectory,
                limit: pageSize,
                offset: 0
            )
            await MainActor.run {
                entries = result.entries
                hasMore = result.hasMore
                totalCount = result.totalCount
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore && hasMore else { return }
        isLoadingMore = true

        do {
            let result = try await rpcClient.misc.getLedgerEntries(
                workingDirectory: workingDirectory,
                limit: pageSize,
                offset: entries.count
            )
            await MainActor.run {
                entries.append(contentsOf: result.entries)
                hasMore = result.hasMore
                totalCount = result.totalCount
                isLoadingMore = false
            }
        } catch {
            await MainActor.run {
                isLoadingMore = false
            }
        }
    }
}

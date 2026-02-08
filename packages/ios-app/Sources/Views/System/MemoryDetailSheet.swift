import SwiftUI

/// Detail sheet shown when tapping the memory updated notification pill.
/// Lazy-loads the full ledger entry from the server and displays a
/// user-friendly summary followed by structured metadata.
@available(iOS 26.0, *)
struct MemoryDetailSheet: View {
    let title: String
    let entryType: String
    let sessionId: String
    let rpcClient: RPCClient
    @Environment(\.dismiss) private var dismiss

    @State private var ledgerPayload: [String: AnyCodable]?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    if isLoading {
                        loadingView
                            .padding(.horizontal)
                    } else if let error = loadError {
                        errorView(error)
                            .padding(.horizontal)
                    } else if let payload = ledgerPayload {
                        ledgerContent(payload)
                    } else {
                        // Fallback — just show title
                        fallbackView
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Memory Updated")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.purple)
        .preferredColorScheme(.dark)
        .task {
            await loadLedgerEntry()
        }
    }

    // MARK: - Loading

    private func loadLedgerEntry() async {
        do {
            let result = try await rpcClient.eventSync.getHistory(
                sessionId: sessionId,
                types: ["memory.ledger"],
                limit: 10
            )
            // Find the matching entry by title (most recent first)
            if let match = result.events.last(where: {
                ($0.payload["title"]?.value as? String) == title
            }) {
                ledgerPayload = match.payload
            } else if let last = result.events.last {
                // Fallback to most recent ledger entry
                ledgerPayload = last.payload
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Content Views

    private func ledgerContent(_ payload: [String: AnyCodable]) -> some View {
        let input = payload["input"]?.value as? String
        let actions = (payload["actions"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
        let model = payload["model"]?.value as? String
        let tokenCost = payload["tokenCost"]?.value as? [String: Any]

        return VStack(spacing: 16) {
            metadataHeader(model: model, tokenCost: tokenCost)
                .padding(.horizontal)

            if let input {
                summarySection(input: input, actions: actions)
                    .padding(.horizontal)
            }

            rawPayloadSection(payload)
                .padding(.horizontal)
        }
    }

    // MARK: - Summary

    private func summarySection(input: String, actions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(input)
                .font(TronTypography.mono(size: TronTypography.sizeBody3))
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !actions.isEmpty {
                Divider()
                    .background(.purple.opacity(0.2))

                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.purple.opacity(0.6))
                            .padding(.top, 2)
                        Text(action)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineSpacing(3)
                    }
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Raw Payload

    private func rawPayloadSection(_ payload: [String: AnyCodable]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ledger Entry")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(prettyPrintPayload(payload))
                    .font(TronTypography.mono(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Metadata Header

    private func metadataHeader(model: String?, tokenCost: [String: Any]?) -> some View {
        HStack(spacing: 16) {
            if let model {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    Text(formatModelDisplayName(model))
                        .font(TronTypography.codeSM)
                }
                .foregroundStyle(.white.opacity(0.5))
            }

            if let cost = tokenCost,
               let input = cost["input"] as? Int,
               let output = cost["output"] as? Int {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    Text("\(formatTokens(input)) in / \(formatTokens(output)) out")
                        .font(TronTypography.codeSM)
                }
                .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
        }
    }

    // MARK: - State Views

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .tint(.purple)
            Text("Loading ledger entry...")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(TronTypography.sans(size: TronTypography.sizeXL))
                .foregroundStyle(.purple.opacity(0.5))
            Text("Could not load ledger entry")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var fallbackView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "brain.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXL))
                    .foregroundStyle(.purple)
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Helpers

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func prettyPrintPayload(_ payload: [String: AnyCodable]) -> String {
        let raw = payload.mapValues { $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: raw)
        }
        return string
    }
}

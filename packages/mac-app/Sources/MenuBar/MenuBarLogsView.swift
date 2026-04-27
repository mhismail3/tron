import AppKit
import SwiftUI

struct MenuBarLogsView: View {
    @State private var phase: Phase = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Tron Logs")
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(Color.tronEmerald)
                Spacer()
                Button("Refresh") {
                    Task { await refresh() }
                }
                .disabled(phase == .loading)
                Button("Copy") {
                    copyCurrentLogs()
                }
                .disabled(!phase.hasCopyableText)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 360)
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading logs…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            Text("No logs found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let logs):
            ScrollView {
                Text(logs)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Logs unavailable")
                    .font(TronTypography.wizardSubheadline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .wizardGlassCard()
        }
    }

    @MainActor
    private func refresh() async {
        phase = .loading
        let result = await MenuBarLogReader.fetchRecentLogs()
        switch result {
        case .success(let logs):
            let trimmed = logs.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = trimmed.isEmpty ? .empty : .loaded(logs)
        case .failure(let error):
            phase = .failed(error.message)
        }
    }

    private func copyCurrentLogs() {
        guard case .loaded(let logs) = phase else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(logs, forType: .string)
    }

    private enum Phase: Equatable {
        case loading
        case empty
        case loaded(String)
        case failed(String)

        var hasCopyableText: Bool {
            if case .loaded(let logs) = self {
                return !logs.isEmpty
            }
            return false
        }
    }
}

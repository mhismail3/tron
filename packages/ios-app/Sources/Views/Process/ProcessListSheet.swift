import SwiftUI

/// Sheet showing tracked background processes as passive runtime evidence.
/// Presented from the toolbar menu when active processes exist.
@available(iOS 26.0, *)
struct ProcessListSheet: View {
    let processState: ProcessState
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if processState.allProcessesSorted.isEmpty {
                    emptyState
                } else {
                    processList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Background Processes", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm, phoneSizing: .unchanged, phoneBackground: .unchanged)
    }

    // MARK: - Subviews

    private var processList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(processState.allProcessesSorted) { process in
                    ProcessRow(process: process)
                }
            }
            .padding()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.tronTextMuted.opacity(0.5))
            Text("No background processes")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Process Row

@available(iOS 26.0, *)
private struct ProcessRow: View {
    let process: ProcessState.TrackedProcess

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(process.label)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(process.kind)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                    if let duration = process.durationMs {
                        Text(formatDuration(duration))
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    } else if process.status == .running {
                        Text("running...")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronEmerald.opacity(0.7))
                    }
                    if let exitCode = process.exitCode, exitCode != 0 {
                        Text("exit \(exitCode)")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronError)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.tronSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch process.status {
        case .running, .backgrounded:
            ProgressView()
                .controlSize(.small)
                .tint(.tronEmerald)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tronEmerald)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tronError)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60_000 {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        } else {
            let seconds = ms / 1000
            let minutes = seconds / 60
            let remaining = seconds % 60
            return "\(minutes)m \(remaining)s"
        }
    }
}

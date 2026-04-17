import SwiftUI
import UIKit

// MARK: - Source Control Status Header

/// Compact header shown at the top of `SourceControlSheet`.
///
/// Always shows the current branch, worktree path (tap-to-copy), a row of
/// divergence chips (ahead/behind main, ahead/behind origin), and any repo-wide
/// lock badge that another session holds. Pending-merge crash-recovery banners
/// attach here too.
@available(iOS 26.0, *)
struct SourceControlStatusHeader: View {
    let branch: String
    let worktreePath: String?
    let divergence: RepoDivergence?
    let lockHolder: RepoSessionLock?
    let pendingMerge: PendingMergeBanner?

    // Callbacks
    var onContinueSubagent: (() -> Void)?
    var onAbortPending: (() -> Void)?

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identityRow
            if let chips = divergenceChips, !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            divergenceChip(chip)
                        }
                    }
                }
            }
            if let lockHolder {
                lockBadge(lockHolder)
            }
            if let pendingMerge {
                pendingMergeBanner(pendingMerge)
            }
        }
        .padding(12)
        .sectionFill(.tronTeal, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Identity Row

    private var identityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTeal)
                    .frame(width: 18)
                Text(branch)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTeal)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let worktreePath {
                Button { copyPath(worktreePath) } label: {
                    Text(worktreePath.abbreviatingHomeDirectory)
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(didCopy ? .tronEmerald : .tronTextMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyPath(_ path: String) {
        UIPasteboard.general.string = path
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            didCopy = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }

    // MARK: Divergence Chips

    struct DivergenceChip: Identifiable {
        let id = UUID()
        let label: String
        let kind: Kind
        var isEmpty: Bool { label == "0" }

        enum Kind {
            case aheadMain, behindMain, aheadOrigin, behindOrigin
        }
    }

    /// Build the chip row, omitting any pair whose value is `nil` (not
    /// applicable — e.g. no origin remote). Zero values still render but
    /// fade, so a truly synced state is distinguishable from a missing
    /// remote.
    private var divergenceChips: [DivergenceChip]? {
        guard let d = divergence else { return nil }
        var chips: [DivergenceChip] = []
        if let a = d.aheadMain { chips.append(.init(label: "\(a)", kind: .aheadMain)) }
        if let b = d.behindMain { chips.append(.init(label: "\(b)", kind: .behindMain)) }
        if d.hasOrigin {
            if let a = d.aheadOrigin { chips.append(.init(label: "\(a)", kind: .aheadOrigin)) }
            if let b = d.behindOrigin { chips.append(.init(label: "\(b)", kind: .behindOrigin)) }
        }
        return chips.isEmpty ? nil : chips
    }

    private func divergenceChip(_ chip: DivergenceChip) -> some View {
        let (icon, tint, label): (String, Color, String) = {
            switch chip.kind {
            case .aheadMain: return ("arrow.up", .tronEmerald, "main")
            case .behindMain: return ("arrow.down", .tronAmber, "main")
            case .aheadOrigin: return ("arrow.up", .tronSky, "origin")
            case .behindOrigin: return ("arrow.down", .tronCoral, "origin")
            }
        }()
        let faded = chip.isEmpty

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(chip.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
        }
        .foregroundStyle(faded ? Color.tronTextMuted : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill((faded ? Color.tronTextMuted : tint).opacity(0.12))
        }
        .opacity(faded ? 0.55 : 1)
    }

    // MARK: Lock Badge

    private func lockBadge(_ lock: RepoSessionLock) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.tronAmber)
                .scaleEffect(0.75)
            Text("Session \(lock.shortSessionId) is \(lock.opDescription) main…")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.tronAmber.opacity(0.12))
        }
    }

    // MARK: Pending-Merge Banner (crash recovery)

    private func pendingMergeBanner(_ pending: PendingMergeBanner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pending merge from previous session")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(pending.sourceBranch) → \(pending.targetBranch) · \(pending.strategy)")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    onContinueSubagent?()
                } label: {
                    Text("Continue Subagent")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.tronEmerald))
                }
                .buttonStyle(.plain)
                Button {
                    onAbortPending?()
                } label: {
                    Text("Abort Now")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronError)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.tronError.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronWarning.opacity(0.10))
        }
    }
}

// MARK: - Supporting Types

/// Lightweight repo-wide lock info for header rendering.
struct RepoSessionLock: Equatable {
    let sessionId: String
    let op: String // "syncMain" | "finalizeSession"

    var shortSessionId: String { String(sessionId.prefix(6)) }
    var opDescription: String {
        switch op {
        case "syncMain": "syncing"
        case "finalizeSession": "finalizing"
        default: "modifying"
        }
    }
}

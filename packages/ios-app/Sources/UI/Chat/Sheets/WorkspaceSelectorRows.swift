import SwiftUI

struct WorkspaceQuickPath: Identifiable, Equatable {
    let path: String
    let title: String
    let subtitle: String
    let icon: String

    var id: String { path }
}

struct WorkspaceQuickPathPill: View {
    let row: WorkspaceQuickPath
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: row.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 14)

                Text(row.title)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(isSelected ? 0.2 : 0.08)).interactive(),
            in: Capsule()
        )
        .accessibilityLabel("\(row.title), \(row.subtitle)")
    }
}

struct WorkspaceDirectoryActionPill: View {
    let icon: String
    let title: String
    let subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronEmerald)

                    if let subtitle {
                        Text(subtitle)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, subtitle == nil ? 10 : 9)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(0.1)).interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

struct WorkspaceDirectoryEntryRow: View {
    let entry: WorkspaceDirectoryEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.isSymlink ? "folder.badge.questionmark" : "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)

                Text(entry.name)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronOverlay(0.07)).interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

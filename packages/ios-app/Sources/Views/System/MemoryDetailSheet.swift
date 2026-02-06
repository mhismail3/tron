import SwiftUI

/// Detail sheet shown when tapping the memory updated notification pill.
/// Displays the ledger entry title, type badge, and description.
@available(iOS 26.0, *)
struct MemoryDetailSheet: View {
    let title: String
    let entryType: String
    @Environment(\.dismiss) private var dismiss

    private var entryTypeLabel: String {
        switch entryType {
        case "feature": return "Feature"
        case "bugfix": return "Bug Fix"
        case "refactor": return "Refactor"
        case "docs": return "Documentation"
        case "config": return "Configuration"
        case "research": return "Research"
        case "conversation": return "Conversation"
        default: return entryType.capitalized
        }
    }

    private var entryTypeIcon: String {
        switch entryType {
        case "feature": return "plus.circle.fill"
        case "bugfix": return "ladybug.fill"
        case "refactor": return "arrow.triangle.2.circlepath.circle.fill"
        case "docs": return "doc.text.fill"
        case "config": return "gearshape.fill"
        case "research": return "magnifyingglass.circle.fill"
        default: return "brain.fill"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    headerSection
                        .padding(.horizontal)

                    infoSection
                        .padding(.horizontal)
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
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entry")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "brain.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.purple)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.white)

                        HStack(spacing: 6) {
                            Image(systemName: entryTypeIcon)
                                .font(TronTypography.codeSM)
                            Text(entryTypeLabel)
                                .font(TronTypography.codeSM)
                        }
                        .foregroundStyle(.purple.opacity(0.8))
                    }

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
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.purple)

                    Text("Ledger Entry")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.purple)

                    Spacer()
                }

                Text("Memory ledger entries are written after each response cycle to track session progress. They capture what was done, decisions made, and lessons learned.")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

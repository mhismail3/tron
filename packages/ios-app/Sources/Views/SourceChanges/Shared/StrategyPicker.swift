import SwiftUI

/// Anything pickable by `StrategyPicker` — must expose a label and SF
/// Symbol icon. Conformed to by the strategy enums on each git sub-sheet
/// (`RebaseOnMainSubSheet.Strategy`, `MergeChangesSubSheet.MergeStrategy`).
protocol StrategyDisplayable: Hashable, Identifiable {
    var label: String { get }
    var icon: String { get }
}

/// Three-way pill picker that the rebase / finalize sub-sheets use to
/// pick a merge strategy. Iterates `S.allCases` so adding a new variant
/// to the enum automatically renders an extra pill.
struct StrategyPicker<S>: View
where
    S: StrategyDisplayable & CaseIterable,
    S.AllCases: RandomAccessCollection
{
    @Binding var selection: S
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(S.allCases) { strategy in
                Button {
                    selection = strategy
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: strategy.icon)
                            .font(TronTypography.sans(size: TronTypography.sizeBody3))
                        Text(strategy.label)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    }
                    .foregroundStyle(selection == strategy ? accent : .tronTextMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        if selection == strategy {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(accent.opacity(0.15))
                                .padding(4)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }
}

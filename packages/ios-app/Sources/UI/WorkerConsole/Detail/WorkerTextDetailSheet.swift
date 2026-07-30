import SwiftUI

/// Stable subordinate sheet for unbounded human-readable worker detail.
///
/// Technical timeline rows live here instead of expanding the primary run
/// sheet or sharing state with its authoritative graph projection.
struct WorkerTextDetailSheet: View {
    let title: String
    let values: [String]
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Text(value)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(accent, cornerRadius: 10, subtle: true, interactive: false)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(accent)
    }
}

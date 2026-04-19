import SwiftUI

/// Full-width "Open Conflict Resolver" CTA. Used by sub-sheets that
/// dismiss themselves and route to `ConflictResolverSubSheet` after a
/// merge / rebase / sync surfaces conflicts.
///
/// The host sub-sheet owns the dismiss + route call: this view is a
/// pure button so it never needs `@Environment(\.dismiss)`.
struct OpenConflictResolverButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "wand.and.stars")
                Text("Open Conflict Resolver")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
            }
            .foregroundStyle(.tronRose)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.tronRose.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
    }
}

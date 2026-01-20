import SwiftUI

// MARK: - Glass Action Sheet (Custom iOS 26 Liquid Glass Style)

/// Role for glass action buttons
enum GlassActionRole {
    case `default`
    case destructive
    case cancel
}

/// A single action in a glass action sheet
struct GlassAction {
    let title: String
    let icon: String?
    let color: Color
    let role: GlassActionRole
    let action: () -> Void
}

/// Custom action sheet with iOS 26 liquid glass styling
/// Supports custom colors and icons (unlike native confirmationDialog)
@available(iOS 26.0, *)
struct GlassActionSheet: View {
    let actions: [GlassAction]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button {
                    action.action()
                } label: {
                    HStack(spacing: 8) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        }
                        Text(action.title)
                            .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: action.role == .cancel ? .regular : .medium))
                    }
                    .foregroundStyle(action.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .contentShape(Capsule())
                    .background {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(
                                .regular.tint(action.color.opacity(action.role == .cancel ? 0.1 : 0.25)),
                                in: Capsule()
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 200)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .presentationBackground(.clear)
    }
}

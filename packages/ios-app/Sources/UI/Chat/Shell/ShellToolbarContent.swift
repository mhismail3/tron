import SwiftUI

struct ShellTopBarOverlay: View {
    let title: String
    let accent: Color
    let actions: ShellToolbarActions
    var onToggleSidebar: (() -> Void)? = nil

    var body: some View {
        TronNavigationTopBarOverlay {
            ZStack {
                Text(title)
                    .font(TronTypography.sans(size: 20, weight: .bold))
                    .foregroundStyle(accent)

                HStack {
                    if let onToggleSidebar {
                        TronToolbarIconButton(
                            systemImage: "sidebar.leading",
                            accessibilityLabel: "Show sidebar",
                            color: accent,
                            font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium),
                            action: onToggleSidebar
                        )
                        .hoverEffect(.highlight)
                    } else {
                        ShellTopBarLogo(accent: accent)
                    }

                    Spacer()

                    TronToolbarIconButton(
                        systemImage: "gearshape",
                        accessibilityLabel: "Settings",
                        color: accent,
                        font: TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium),
                        action: actions.onSettings
                    )
                    .hoverEffect(.highlight)
                }
            }
        }
    }
}

private struct ShellTopBarLogo: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.tronOverlay(0.24))
                .overlay {
                    Circle()
                        .stroke(Color.tronTextPrimary.opacity(0.10), lineWidth: 1)
                }

            Image("TronLogoVector")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 28)
                .offset(y: 1)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("Tron")
    }
}

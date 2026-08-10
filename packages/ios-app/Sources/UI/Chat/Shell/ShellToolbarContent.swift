import SwiftUI

enum TronPrimaryPage: String, CaseIterable, Identifiable, Sendable {
    case sessions = "Sessions"
    case engine = "Engine"
    case activity = "Activity"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .engine: "cpu"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct ShellToolbarContent: ToolbarContent {
    let title: String
    let accent: Color
    let actions: ShellToolbarActions
    var onToggleSidebar: (() -> Void)? = nil
    var primaryPage: Binding<TronPrimaryPage>? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let onToggleSidebar {
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.leading")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Show sidebar")
                .hoverEffect(.highlight)
            } else if let primaryPage {
                Menu {
                    ForEach(TronPrimaryPage.allCases) { page in
                        Button {
                            primaryPage.wrappedValue = page
                        } label: {
                            Label {
                                Text(page.rawValue)
                            } icon: {
                                Image(systemName: primaryPage.wrappedValue == page
                                    ? "checkmark"
                                    : page.systemImage)
                            }
                        }
                    }
                } label: {
                    tronLogo
                }
                .menuOrder(.fixed)
                .accessibilityLabel("Open Tron navigation")
            } else {
                tronLogo
            }
        }
        ToolbarItem(placement: .principal) {
            Text(title)
                .font(TronTypography.sans(size: 20, weight: .bold))
                .foregroundStyle(accent)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let onRefresh = actions.onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Refresh")
                .hoverEffect(.highlight)
            }
            Button(action: actions.onSettings) {
                Image(systemName: "gearshape")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(accent)
            }
            .accessibilityLabel("Settings")
            .hoverEffect(.highlight)
        }
    }

    private var tronLogo: some View {
        Image("TronLogoVector")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 28)
            .offset(y: 1)
            .foregroundStyle(accent)
            .accessibilityLabel("Tron")
    }
}

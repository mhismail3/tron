import SwiftUI

enum ModelSelectionAvailability: Equatable {
    case ready
    case blocked(String)
    case applying

    var canSelect: Bool { self == .ready }
    var isApplying: Bool { self == .applying }

    var accessibilityValue: String {
        switch self {
        case .ready: ""
        case .blocked(let reason): reason
        case .applying: "Applying configuration"
        }
    }
}

struct ModelSelectionLockInfoLink: View {
    let reason: String
    var body: some View {
        TronProgressiveSheetLink(
            accessibilityLabel: "Why configuration is unavailable"
        ) {
            ScrollView {
                TronInfoCard(icon: "lock", text: reason, accent: .tronPrimary)
                    .padding(18)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Configuration")
        } label: {
            Image(systemName: "lock")
                .font(TronTypography.buttonSM)
                .tronToolbarAction()
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityValue(reason)
        .accessibilityHint("Opens the configuration availability explanation")
    }
}

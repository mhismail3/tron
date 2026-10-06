import SwiftUI

/// Value-only presentation of the owning session's admission/receipt state.
/// It never infers settlement or changes mutation admission.
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

/// Lock explanations use the ordinary progressive information sheet, reachable
/// by touch and VoiceOver, instead of inserting status copy into model content.
struct ModelSelectionLockInfoLink: View {
    let reason: String
    var body: some View {
        TronProgressiveSheetLink(
            accessibilityLabel: "Why configuration is unavailable",
            accent: .tronPurple,
            detents: .fixed([.medium, .large])
        ) {
            ScrollView {
                TronInfoCard(icon: "lock", text: reason, accent: .tronPurple)
                    .padding(18)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Configuration", accent: .tronPurple)
        } label: {
            Image(systemName: "lock")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronPurple)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityValue(reason)
        .accessibilityHint("Opens the configuration availability explanation")
    }
}

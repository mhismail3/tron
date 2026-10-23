import SwiftUI
import TronMobileCore

/// A session row's trailing relative-time (or waiting) label. It reserves the
/// widest label `GatewayTimestamp.relativeDescription` realistically produces,
/// measured in the shared code font at the current Dynamic Type size, so a
/// ticking label never changes the width left for the row's title
/// and the title keeps one truncation point.
struct SessionRowRelativeTime: View {
    let text: String
    let isWaiting: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            ForEach(GatewayTimestamp.relativeDescriptionWidthTemplates, id: \.self) { template in
                Text(template).hidden()
            }
            Text(text)
                .foregroundStyle(isWaiting ? Color.tronAmber : Color.tronTextMuted)
        }
        .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

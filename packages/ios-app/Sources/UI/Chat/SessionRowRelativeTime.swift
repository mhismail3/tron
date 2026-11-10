import SwiftUI
import TronMobileCore

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

import SwiftUI

/// Caption text displayed below a settings card.
struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .padding(.top, 6)
            .padding(.horizontal, 4)
    }
}

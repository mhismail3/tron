import SwiftUI

struct DoneStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tron lives in your menu bar from here on. Click the icon any time to copy your pairing info, restart Tron, or send feedback.")
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

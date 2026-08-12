import SwiftUI

/// Done step. The shell owns the icon, title, progress pill, and
/// bottom action bar. Its "Open menu bar" action commits the durable
/// sentinel before notifying AppDelegate. This view owns only the
/// celebratory description text.
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

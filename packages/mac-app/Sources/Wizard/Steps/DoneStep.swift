import SwiftUI
import os.log

/// Done step. The shell owns the icon, title, progress pill, and
/// the bottom action bar (no secondary; primary "Open menu bar"
/// posts `tronWizardDidComplete`). This view contributes only the
/// celebratory description text and the side effect of touching the
/// onboarded sentinel so a kill+relaunch lands in menu-bar mode.
struct DoneStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tron lives in your menu bar from here on. Click the icon any time to copy your pairing info, restart the server, or send feedback.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .onAppear {
            // Touch the sentinel atomically so the next launch lands
            // in menu-bar mode. Routes through `setup` so tests can
            // substitute a no-op without touching disk.
            //
            // Failure is rare (disk full, perms tampered) but real —
            // if we silently swallow it the user clicks "Open menu
            // bar", quits, relaunches, and lands back at the wizard
            // with no breadcrumb. NSLog at least surfaces the cause
            // in Console.app.
            do {
                try setup.touchOnboardedSentinel()
            } catch {
                NSLog("[Tron] Failed to write onboarded sentinel: \(error.localizedDescription)")
            }
        }
    }
}

import SwiftUI
import os.log

struct DoneStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 96))
                .foregroundStyle(.green)
                .padding(.top, 32)
            Text("You're all set")
                .font(.largeTitle.bold())
            Text("Tron lives in your menu bar from here on. Click the icon any time to copy your pairing info, restart the server, or send feedback.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 16)
            Button {
                NotificationCenter.default.post(name: .tronWizardDidComplete, object: nil)
            } label: {
                Text("Open menu bar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
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

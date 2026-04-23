import SwiftUI

struct DoneStep: View {
    @Bindable var state: WizardState

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
            // touch sentinel atomically so the next launch lands in
            // menu-bar mode.
            try? OnboardedSentinelWriter.touch(at: TronPaths.onboardedMarkerPath)
        }
    }
}

import SwiftUI

/// Optional local transcription setup. The server is already installed
/// and reachable by this point; this step seeds the tiny sidecar source
/// files and decides whether to flip `server.transcription.enabled` and
/// restart the helper so the Parakeet model can download in the background.
struct TranscriptionStep: View {
    @Bindable var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TranscriptionStepContent.intro)
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WizardInfoCard {
                WizardIconTextRow(alignment: .top) {
                    Image(systemName: state.transcriptionEnabledSelection ? "waveform.badge.checkmark" : "waveform")
                        .font(.title)
                        .foregroundStyle(state.transcriptionEnabledSelection ? Color.tronEmerald : Color.secondary)
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: transcriptionBinding) {
                            Text(TranscriptionStepContent.toggleTitle)
                                .font(TronTypography.wizardSubheadline)
                        }
                        .toggleStyle(.switch)
                        .disabled(state.transcriptionIsApplying)

                        Text(TranscriptionStepContent.toggleBody)
                            .font(TronTypography.wizardCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if state.transcriptionIsApplying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.transcriptionEnabledSelection ? "Starting transcription support..." : "Saving preference...")
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if case .failed(let message) = state.transcriptionOutcome {
                WizardInfoCard {
                    WizardIconTextRow(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcription setup needs attention")
                                .font(TronTypography.wizardSubheadline)
                            Text(message)
                                .font(TronTypography.wizardCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(WizardLayout.transitionAnimation, value: state.transcriptionEnabledSelection)
        .animation(WizardLayout.transitionAnimation, value: state.transcriptionIsApplying)
        .animation(WizardLayout.transitionAnimation, value: state.transcriptionOutcome)
    }

    private var transcriptionBinding: Binding<Bool> {
        Binding(
            get: { state.transcriptionEnabledSelection },
            set: { newValue in
                state.transcriptionEnabledSelection = newValue
                state.transcriptionOutcome = nil
            }
        )
    }
}

enum TranscriptionStepContent {
    static let intro = "Voice transcription runs locally on this Mac. It uses Apple's MLX stack and downloads a Parakeet model the first time it starts."
    static let toggleTitle = "Enable local transcription"
    static let toggleBody = "The model cache stays under ~/.tron/internal/transcription/models/hf and can be added later from Settings."
}

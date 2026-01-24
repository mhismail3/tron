import SwiftUI

/// Recording sheet for voice notes with sine wave visualization and post-recording confirmation.
/// Styled to match NewSessionFlow sheet.
@available(iOS 26.0, *)
struct VoiceNotesRecordingSheet: View {
    @StateObject private var recorder = VoiceNotesRecorder()
    @State private var isSaving = false
    @State private var errorMessage: String?

    let rpcClient: RPCClient
    let onComplete: (String) -> Void  // Receives filename
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Duration display
                Text(formattedDuration)
                    .font(TronTypography.timerDisplay)
                    .foregroundStyle(.white)

                // Sine wave visualization
                SineWaveView(audioLevel: recorder.audioLevel, color: .tronEmerald)
                    .frame(height: 80)
                    .padding(.horizontal, 20)

                // Status text
                Group {
                    if isSaving {
                        HStack(spacing: 8) {
                            ProgressView().tint(.tronEmerald)
                            Text("Transcribing...")
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    } else if recorder.isRecording {
                        Text("Recording...")
                            .foregroundStyle(.tronEmerald)
                    } else if recorder.hasStopped {
                        Text("Ready to save")
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text("Tap mic to start")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .font(TronTypography.messageBody)

                // Max duration indicator
                if recorder.isRecording {
                    Text("Max: 5 minutes")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.white.opacity(0.3))
                }

                Spacer()

                // Control buttons
                controlButtons
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Voice Note")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
        .onAppear {
            // Auto-start recording when sheet appears
            Task {
                try? await recorder.startRecording()
            }
        }
        .onDisappear {
            recorder.cancelRecording()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var formattedDuration: String {
        let minutes = Int(recorder.recordingDuration) / 60
        let seconds = Int(recorder.recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private var controlButtons: some View {
        if recorder.hasStopped {
            // Post-recording: Cancel, Save, Re-record - icons only, vertically aligned
            HStack(alignment: .center, spacing: 32) {
                // Cancel - smaller button
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 52, height: 52)
                }
                .glassEffect(.regular.tint(Color.white.opacity(0.25)).interactive(), in: .circle)
                .disabled(isSaving)

                // Save - larger primary button, vertically centered with others
                Button(action: handleSave) {
                    if isSaving {
                        ProgressView().tint(.white)
                            .frame(width: 64, height: 64)
                    } else {
                        Image(systemName: "checkmark")
                            .font(TronTypography.sans(size: TronTypography.sizeHero, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                    }
                }
                .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.65)).interactive(), in: .circle)
                .disabled(isSaving)

                // Re-record - smaller button
                Button(action: handleReRecord) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 52, height: 52)
                }
                .glassEffect(.regular.tint(Color.white.opacity(0.25)).interactive(), in: .circle)
                .disabled(isSaving)
            }
        } else {
            // Recording state: Cancel and Stop/Start
            HStack(spacing: 48) {
                // Cancel
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 52, height: 52)
                }
                .glassEffect(.regular.tint(Color.white.opacity(0.25)).interactive(), in: .circle)

                // Record/Stop
                Button(action: handleRecordTap) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeHero, weight: .semibold))
                        .foregroundStyle(recorder.isRecording ? .white : .tronEmerald)
                        .frame(width: 72, height: 72)
                }
                .glassEffect(
                    .regular.tint(recorder.isRecording ? Color.red.opacity(0.6) : Color.tronEmerald.opacity(0.6)).interactive(),
                    in: .circle
                )
            }
        }
    }

    // MARK: - Actions

    private func handleRecordTap() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            Task {
                do {
                    try await recorder.startRecording()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleReRecord() {
        recorder.reset()
        Task {
            try? await recorder.startRecording()
        }
    }

    private func handleSave() {
        guard let url = recorder.getRecordingURL() else { return }

        isSaving = true
        recorder.markSaving()

        Task {
            do {
                let data = try Data(contentsOf: url)

                // Fire-and-forget: dismiss immediately, save in background
                let result = try await rpcClient.saveVoiceNote(
                    audioData: data
                )

                // Clean up temp file
                try? FileManager.default.removeItem(at: url)

                await MainActor.run {
                    onComplete(result.filename)
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

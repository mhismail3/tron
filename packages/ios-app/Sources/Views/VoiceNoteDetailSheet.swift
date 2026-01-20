import SwiftUI

/// Detail view showing full transcription of a voice note.
@available(iOS 26.0, *)
struct VoiceNoteDetailSheet: View {
    let note: VoiceNoteMetadata

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    // Metadata header
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tronEmerald)
                        Text(note.formattedDate)
                            .font(TronTypography.headline)
                            .foregroundStyle(.tronEmerald)

                        Spacer()

                        Text(note.formattedDuration)
                            .font(TronTypography.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding()
                    .glassEffect(
                        .regular.tint(Color.tronPhthaloGreen.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                    // Transcription content
                    Text(note.transcript)
                        .font(TronTypography.mono(size: TronTypography.sizeBodyLG))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 24, height: 24)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Voice Note")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: note.transcript) {
                        Image(systemName: "square.and.arrow.up")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 24, height: 24)
                    }
                    .disabled(note.transcript.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }
}

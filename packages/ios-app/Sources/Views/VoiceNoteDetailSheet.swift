import SwiftUI

/// Detail view showing full transcription of a voice note.
@available(iOS 26.0, *)
struct VoiceNoteDetailSheet: View {
    let note: VoiceNoteMetadata

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Metadata header
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tronEmerald)
                        Text(note.formattedDate)
                            .font(.headline)
                            .foregroundStyle(.tronEmerald)

                        Spacer()

                        Text(note.formattedDuration)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding()
                    .glassEffect(
                        .regular.tint(Color.tronPhthaloGreen.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                    // Transcription content
                    Text(note.preview)
                        .font(.system(size: 15, design: .monospaced))
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
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 24, height: 24)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Voice Note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: note.preview) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 24, height: 24)
                    }
                    .disabled(note.preview.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }
}

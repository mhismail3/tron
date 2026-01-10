import SwiftUI

/// List view showing saved voice note transcriptions.
@available(iOS 26.0, *)
struct VoiceNotesListView: View {
    let rpcClient: RPCClient
    let onVoiceNote: () -> Void
    let onSettings: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?

    @State private var notes: [VoiceNoteMetadata] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedNote: VoiceNoteMetadata?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isLoading && notes.isEmpty {
                ProgressView()
                    .tint(.tronEmerald)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                errorView(error)
            } else if notes.isEmpty {
                emptyView
            } else {
                notesList
            }

            // Floating mic button
            FloatingVoiceNotesButton(action: onVoiceNote)
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(NavigationMode.allCases, id: \.self) { mode in
                        Button {
                            onNavigationModeChange?(mode)
                        } label: {
                            Label(mode.rawValue, systemImage: mode == .agents ? "cpu" : "waveform")
                        }
                    }
                } label: {
                    Image("TronLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("VOICE NOTES")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .tracking(2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .sheet(item: $selectedNote) { note in
            VoiceNoteDetailSheet(note: note)
        }
        .task {
            await loadNotes()
        }
        .refreshable {
            await loadNotes()
        }
    }

    private var notesList: some View {
        List {
            ForEach(notes) { note in
                VoiceNoteRow(note: note)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .onTapGesture {
                        selectedNote = note
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Voice Notes")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Tap the mic button to record")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text(error)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await loadNotes() }
            }
            .foregroundStyle(.tronEmerald)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadNotes() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await rpcClient.listVoiceNotes(limit: 100)
            await MainActor.run {
                notes = result.notes
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

/// Row for a single voice note in the list.
@available(iOS 26.0, *)
struct VoiceNoteRow: View {
    let note: VoiceNoteMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronEmerald)

                Text(note.formattedDate)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald)

                Spacer()

                Text(note.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }

            if let language = note.language {
                Text(language.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald.opacity(0.6))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

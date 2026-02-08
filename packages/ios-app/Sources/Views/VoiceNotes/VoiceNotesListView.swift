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
                    .tint(.tronTeal)
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
                            Label(mode.rawValue, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image("TronLogo")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                        .foregroundStyle(.tronTeal)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("VOICE NOTES")
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.tronTeal)
                    .tracking(2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronTeal)
                }
            }
        }
        .sheet(item: $selectedNote) { note in
            VoiceNoteDetailSheet(note: note)
        }
        .task {
            await loadNotes()
        }
    }

    private func deleteNote(_ note: VoiceNoteMetadata) async {
        do {
            _ = try await rpcClient.media.deleteVoiceNote(filename: note.filename)
            await MainActor.run {
                notes.removeAll { $0.filename == note.filename }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Menu {
                            Section("This will permanently delete the note from your machine.") {
                                Button(role: .destructive) {
                                    Task { await deleteNote(note) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            Button(role: .cancel) {
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .tint(.red)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(TronTypography.sans(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Voice Notes")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Tap the mic button to record")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(TronTypography.sans(size: 40))
                .foregroundStyle(.red)

            Text(error)
                .font(TronTypography.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Button("Retry") {
                Task { await loadNotes() }
            }
            .foregroundStyle(.tronTeal)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadNotes() async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await rpcClient.media.listVoiceNotes(limit: 100)
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
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTeal)

                Text(note.formattedDate)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTeal)

                Spacer()

                Text(note.formattedDuration)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .regular.tint(Color.tronTeal.opacity(0.12)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
    }
}


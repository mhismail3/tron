import SwiftUI

struct AgentInstructionsSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = true
    @State private var loadingRequest: UUID?

    private var instructions: String? {
        model.context?.objectValue?["systemPrompt"]?.stringValue
    }

    var body: some View {
        TronDocumentSheet(title: "Agent Instructions") {
            Group {
                if let instructions {
                    PreparedAgentInstructions(instructions: instructions)
                } else if loading {
                    TronLoadingState(label: "Loading instructions…", accent: .tronSessionTeal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TronInfoCard(icon: "doc.text", text: "Instructions are unavailable for this session.", accent: .tronSessionTeal)
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .tronScrollEdgeChrome()
        }
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
        .task(id: PresentationActivityTaskID(
            source: model.sessionContextRevision(for: sessionID),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            let request = UUID()
            loadingRequest = request
            loading = true
            await model.loadContext(sessionID: sessionID)
            guard !Task.isCancelled, loadingRequest == request,
                  presentationActivity.allowsPresentationPublication else { return }
            loading = false
        }
    }
}

/// One detached parser for the mounted instruction document, keyed on the exact
/// source so a completed document is reused across activations instead of
/// re-parsing the whole prompt on the main thread. Mirrors the transcript
/// detail reader and keeps the same predecessor-drain and cancellation owner.
private struct PreparedAgentInstructions: View {
    let instructions: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var preparation = ChatDetailDocumentPreparation()

    var body: some View {
        Group {
            if let document = preparation.document, document.source == instructions {
                ScrollView {
                    TronMarkdownView(document: document, streaming: false)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .onChange(of: preparation.revision, initial: true) { _, _ in
                            preparation.mounted(record: record)
                        }
                }
            } else {
                TronLoadingState(label: "Preparing instructions…", accent: .tronSessionTeal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: instructions,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            let activity = presentationActivity
            await preparation.load(source: instructions, isCurrent: {
                presentationActivity == activity && activity.allowsPresentationPublication
            }, record: record)
        }
        .onDisappear { preparation.retire(record: record) }
    }

    private func record(_ message: String) {
        // Reuses the existing lifecycle diagnostic vocabulary; the message
        // identifies this surface.
        model.lifecycleRecordDiagnostic(
            event: "detail.preparation",
            message: "surface=agent-instructions \(message)"
        )
    }
}

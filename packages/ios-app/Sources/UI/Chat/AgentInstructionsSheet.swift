import SwiftUI

struct AgentInstructionsSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = true
    @State private var loadingRequest: UUID?

    var body: some View {
        TronDocumentSheet(title: "Agent Instructions") {
            Group {
                if let instructions = model.context?.objectValue?["systemPrompt"]?.stringValue {
                    ScrollView {
                        TronMarkdownView(text: instructions, streaming: false)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
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
        .task(id: "\(model.sessionContextRevision(for: sessionID)):\(presentationActivity.allowsPresentationPublication)") {
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

import SwiftUI

struct AgentInstructionsSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = true

    var body: some View {
        TronDocumentSheet(title: "Agent Instructions") {
            Group {
                if let instructions = model.context?.objectValue?["systemPrompt"]?.stringValue {
                    TronReadOnlyTextView(text: instructions)
                } else if loading {
                    TronLoadingState(label: "Loading instructions…", accent: .tronSessionTeal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TronInfoCard(icon: "doc.text", text: "Instructions are unavailable for this session.", accent: .tronSessionTeal)
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .tronTopBlurSurface()
        }
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
        .task(id: "\(model.sessionContextRevision(for: sessionID)):\(presentationActivity.allowsPresentationPublication)") {
            guard presentationActivity.allowsPresentationPublication else { return }
            loading = true
            defer { loading = false }
            await model.loadContext(sessionID: sessionID)
        }
    }
}

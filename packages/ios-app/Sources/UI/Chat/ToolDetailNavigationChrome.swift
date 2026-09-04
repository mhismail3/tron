import SwiftUI

struct ToolDetailNavigationPresentation: Equatable, Sendable {
    let title: String
    let icon: String?

    init(tool: ChatToolPresentation) {
        if let askUser = AskUserToolPresentation.completed(tool: tool) {
            title = askUser.form.title
            icon = nil
        } else {
            title = ToolDetailPresentation.contextualDisplayTitle(for: tool)
            icon = ToolDetailPresentation.sheetTitleIcon(for: tool)
        }
    }
}

struct ToolDetailNavigationTitle: View {
    let tool: ChatToolPresentation

    var body: some View {
        let presentation = ToolDetailNavigationPresentation(tool: tool)
        TronSheetTitle(
            title: presentation.title,
            accent: tool.error ? .tronError : ChatSemanticPillRole.tool.accent,
            icon: presentation.icon
        )
    }
}

extension View {
    /// Tool-owned sheets use principal toolbar titles. Explicit inline mode
    /// prevents NavigationStack from reserving an empty large-title region
    /// above the first scroll row on physical devices.
    func tronToolDetailNavigationChrome() -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }
}

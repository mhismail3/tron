#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Scripted bytes only; the chat chips, display route, loader, Markdown and
/// document navigation are the production owners.
enum HostedDisplayDocumentThemeFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-theme") }
    static var home: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-home") }
    static var images: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-images") }
    static let imageID = "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc41"
    static var authoredHTML: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-html") }
    static let markdown = """
    # Home audit report

    A representative report rendered by Tron's shared Markdown reader.

    [Navigation evidence](https://example.test/evidence)

    ## Summary
    Typography, spacing and body text stay unchanged.

    - [Document details](https://example.test/details)
    - A second observation with **emphasis**.

    > An explanatory note remains secondary text.

    | Source | Evidence |
    | --- | --- |
    | Report | [Source link](https://example.test/source) |
    """
    static let html = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{font:18px system-ui;padding:24px;background:#fff;color:#222}
    a{color:#00a0c0}.warning{color:#b04000}.error{color:#c00030}</style></head>
    <body><h1>Authored document</h1><a href="#details">Authored cyan link</a>
    <p class="warning">Semantic warning</p><p class="error">Semantic error</p>
    <p id="details">This HTML owns its styling; a local artifact is not a Tron theme contract.</p></body></html>
    """
    static var payload: ChatMediaPayload {
        ChatMediaPayload(data: Data((authoredHTML ? html : images ? "# Review images\n\n![Preview](preview.png)\n\n![Missing](missing.png)\n\n![Outside](../outside.png)" : markdown).utf8),
                         mimeType: authoredHTML ? "text/html" : "text/markdown")
    }
    @MainActor static var transcript: [TranscriptItem] {
        var rows = try! JSONSerialization.jsonObject(with: HostedChatDisplayFixture.imageTranscriptData) as! [[String: Any]]
        var display = rows[1]["display"] as! [String: Any]
        let kind = authoredHTML ? "html" : "markdown"
        display["kind"] = kind
        display["title"] = home ? "Home audit report" : "Session summary"
        display["altText"] = "Displayed report"
        display["eligibleSurfaces"] = authoredHTML ? ["sheet", "floating"] : ["sheet", "inline"]
        display["presentation"] = ["requestedSurface": "sheet", "inlineTapAction": "sheet"]
        display["artifact"] = ["id": "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc40",
                               "name": authoredHTML ? "report.html" : "report.md",
                               "mimeType": authoredHTML ? "text/html" : "text/markdown",
                               "size": payload.data.count, "kind": kind]
        if images {
            display["markdownImages"] = [["destination": "preview.png", "artifact": [
                "id": imageID, "name": "preview.png", "mimeType": "image/png", "size": 1024, "kind": "image",
            ]]]
        }
        rows[1]["display"] = display
        return try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }
}

/// Test controls are outside the reader's content. They change the real
/// appearance owner while the same production document sheet stays mounted.
struct HostedDisplayDocumentThemeChanges: View {
    @State private var showingReader = false
    @State private var dark = true

    var body: some View {
        Button("Open theme-change reader") { showingReader = true }
            .tronManagedSheet(isPresented: $showingReader, identity: "fixture.theme-change-reader") {
                AttachmentFilePreviewSheet(
                    name: "report.md", mimeType: "text/markdown",
                    source: .local(id: "theme-change-reader",
                                   data: Data(HostedDisplayDocumentThemeFixture.markdown.utf8)),
                    title: "Theme change reader"
                )
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button("Switch reader theme") {
                            AppearanceSettings.shared.themeColor =
                                AppearanceSettings.shared.themeColor == .burgundy ? .oliveGold : .burgundy
                            // This command-line fixture owns its theme input. Keep
                            // the live mutation from coloring later test launches.
                            UserDefaults.standard.removeObject(forKey: "themeColor")
                        }
                        Button("Switch reader appearance") { dark.toggle() }
                    }
                    .padding()
                    .background(.bar)
                }
                .preferredColorScheme(dark ? .dark : .light)
            }
    }
}
#endif

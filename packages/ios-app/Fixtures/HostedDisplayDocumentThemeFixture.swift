#if HOSTED_TEST
import SwiftUI
import TronMobileCore
import WebKit

enum HostedDisplayDocumentThemeFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-theme") }
    static var home: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-home") }
    static var images: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-images") }
    static let imageID = "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc41"
    static var scriptProbe: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-html-probe") }
    static var scriptProbeControl: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-html-control") }
    static var floating: Bool { ProcessInfo.processInfo.arguments.contains("-display-document-html-floating") }
    static var authoredHTML: Bool { scriptProbe || ProcessInfo.processInfo.arguments.contains("-display-document-html") }
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
    static var scriptProbeHTML: String {
        let defaults = UserDefaults.standard
        let http = "http://127.0.0.1:\(defaults.integer(forKey: "display-html-probe-http"))"
        let idle = "http://127.0.0.1:\(defaults.integer(forKey: "display-html-probe-idle"))"
        let stun = "127.0.0.1:\(defaults.integer(forKey: "display-html-probe-stun"))"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <link rel="preconnect" href="\(idle)/"><link rel="stylesheet" href="\(http)/stylesheet">
        <style>body{margin:0;font:18px system-ui;background:#fff;color:#222;background-image:url("\(http)/css-image")}
        p{margin:0;padding:6px 16px}.pinned{position:sticky;top:0;background:#fff}.tall{height:1600px}</style></head>
        <body><p>First content line</p><p class="pinned">Pinned line</p><p id="state">Script idle</p>
        <div id="log"></div><img src="\(http)/image" alt=""><div class="tall"></div>
        <script>
        const say = text => { const p = document.createElement("p"); p.textContent = text; document.getElementById("log").appendChild(p); };
        const attempt = async run => { try { await run(); } catch (error) {} };
        document.getElementById("state").textContent = "Script ran";
        (async () => {
          await attempt(async () => {
            const source = new Blob(["export const value = 42;"], { type: "text/javascript" });
            say("Module import " + (await import(URL.createObjectURL(source))).value);
          });
          await attempt(async () => {
            const canvas = document.createElement("canvas");
            say("WebGL " + Boolean(canvas.getContext("webgl2") || canvas.getContext("webgl")));
          });
          await attempt(() => new Promise(done => {
            addEventListener("hashchange", done, { once: true });
            setTimeout(done, 3000);
            location.hash = "probe";
          }));
          say("Fragment " + location.hash);
          await attempt(() => { say(eval("'Eval ran'")); });
          await attempt(() => {
            const worker = new Worker(URL.createObjectURL(new Blob(["postMessage(1)"], { type: "text/javascript" })));
            worker.onmessage = () => say("Worker ran");
          });
          await attempt(() => fetch("\(http)/fetch", { mode: "no-cors" }));
          await attempt(() => new Promise(done => {
            const request = new XMLHttpRequest();
            request.onloadend = done; request.open("GET", "\(http)/xhr"); request.send();
          }));
          await attempt(() => navigator.sendBeacon("\(http)/beacon", "x"));
          await attempt(() => new WebSocket("ws://127.0.0.1:\(defaults.integer(forKey: "display-html-probe-http"))/socket"));
          await attempt(() => new EventSource("\(http)/events"));
          await attempt(() => { new Image().src = "\(http)/script-image"; });
          await attempt(() => {
            const script = document.createElement("script"); script.src = "\(http)/script"; document.head.appendChild(script);
          });
          await attempt(() => {
            const link = document.createElement("link"); link.rel = "preconnect"; link.href = "\(idle)/"; document.head.appendChild(link);
          });
          await attempt(() => {
            const frame = document.createElement("iframe"); frame.src = "\(http)/frame"; document.body.appendChild(frame);
          });
          await attempt(() => {
            const frame = document.createElement("iframe"); document.body.appendChild(frame);
            return frame.contentWindow.fetch("\(http)/frame-fetch", { mode: "no-cors" });
          });
          await attempt(() => {
            const body = "fetch('\(http)/worker', { mode: 'no-cors' })";
            new Worker(URL.createObjectURL(new Blob([body], { type: "text/javascript" })));
          });
          for (const scope of [window, document.body.appendChild(document.createElement("iframe")).contentWindow]) {
            await attempt(async () => {
              const peer = new scope.RTCPeerConnection({ iceServers: [{ urls: "stun:\(stun)" }] });
              peer.createDataChannel("x");
              await peer.setLocalDescription(await peer.createOffer());
              await new Promise(done => setTimeout(done, 4000));
            });
          }
          await attempt(() => window.open("\(http)/window"));
          say("Navigation attempted");
          \(scriptProbeControl ? "" : "location.href = \"about:blank\"; await new Promise(done => setTimeout(done, 1000));")
          location.href = "\(http)/navigate";
        })();
        </script></body></html>
        """
    }
    static var payload: ChatMediaPayload {
        ChatMediaPayload(data: Data((scriptProbe ? scriptProbeHTML : authoredHTML ? html : images ? "# Review images\n\n![Preview](preview.png)\n\n![Missing](missing.png)\n\n![Outside](../outside.png)" : markdown).utf8),
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
        display["presentation"] = ["requestedSurface": floating ? "floating" : "sheet", "inlineTapAction": "sheet"]
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

#if DEBUG
struct HostedDisplayHTMLProbeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.loadHTMLString(HostedDisplayDocumentThemeFixture.scriptProbeHTML, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

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

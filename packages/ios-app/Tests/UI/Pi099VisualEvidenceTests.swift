import SwiftUI
import Testing
import UIKit
import TronMobileCore
@testable import TronMobile

/// Failure modes exercised by these captures: long MCP diagnostics must remain
/// readable; details must lead with semantic output rather than JSON; nested
/// failures, images, empty structured-only results and Dynamic Type must not
/// clip or collapse the existing Tron presentation components.
@MainActor
@Suite("Pi 0.99 hosted visual evidence")
struct Pi099VisualEvidenceTests {
    private struct Scene: Identifiable {
        let id: String
        let content: AnyView
    }

    @Test("capture settings, MCP and tool presentations in light/dark and standard/accessibility type")
    func captureConformanceFixtures() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let model = AppModel(client: client, cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"0.99.1","protocolVersion":6,"minProtocolVersion":6,"machineId":"fixture-machine","machineName":"Fixture Mac","gatewayChannel":"stable","capabilities":["sessions.v1","modules.v1"]}"#.utf8))
        try await model.connectHostedGateway(profile: GatewayProfile(id: "fixture", label: "Fixture", host: "gateway.test", port: 9847, machineId: "fixture-machine", deviceId: "fixture-device"), token: "fixture-token")
        let responder = Task { await respondToHostedFixtures(socket) }
        defer { responder.cancel(); Task { await model.teardown(); await client.close() } }
        let scenes = fixtures(model: model)
        try FileManager.default.createDirectory(at: Self.captureDirectory, withIntermediateDirectories: true)
        var artifacts: [String] = []
        for scene in scenes {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    let suffix = size == .large ? "std" : "ax"
                    let name = "\(scene.id)-\(scheme == .light ? "light" : "dark")-\(suffix)"
                    let captureSize = scene.id.hasPrefix("mcp-add-server") && size == .accessibility3
                        ? CGSize(width: 390, height: 1_500)
                        : CGSize(width: 390, height: 844)
                    let view = scene.content
                        .frame(width: captureSize.width, height: captureSize.height, alignment: .top)
                        .background(Color.tronBackground)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                    let image = try await renderHosted(view, size: captureSize, dynamicTypeSize: size, scrollToBottom: scene.id == "tool-codemode-continuation")
                    let data = try #require(image.pngData())
                    let url = Self.captureDirectory.appendingPathComponent("\(name).png")
                    try data.write(to: url, options: .atomic)
                    artifacts.append("packages/ios-app/build/p99-captures/\(name).png")
                }
            }
        }
        let index = try JSONSerialization.data(withJSONObject: ["captures": artifacts], options: [.prettyPrinted, .sortedKeys])
        try index.write(to: Self.captureDirectory.appendingPathComponent("index.json"), options: .atomic)
        #expect(artifacts.count == scenes.count * 4)
        #expect(scenes.map(\.id).contains("mcp-servers-global"))
        #expect(scenes.map(\.id).contains("mcp-add-server-http"))
        #expect(scenes.map(\.id).contains("mcp-add-server-stdio"))
        #expect(scenes.map(\.id).contains("tool-codemode"))
    }

    private func renderHosted<V: View>(_ view: V, size: CGSize, dynamicTypeSize: DynamicTypeSize, scrollToBottom: Bool = false) async throws -> UIImage {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view)
        controller.traitOverrides.preferredContentSizeCategory = dynamicTypeSize == .large ? .large : .accessibilityExtraExtraExtraLarge
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        controller.view.layoutIfNeeded()
        if scrollToBottom {
            let scrollViews = descendants(of: controller.view).compactMap { $0 as? UIScrollView }
            for scrollView in scrollViews {
                let maximum = max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                scrollView.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
            }
            controller.view.layoutIfNeeded()
        }
        defer { window.isHidden = true; window.rootViewController = nil }
        return UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    }

    private func descendants(of view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants(of:)) }

    private static var captureDirectory: URL {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let package = tests.deletingLastPathComponent().deletingLastPathComponent()
        return package.appendingPathComponent("build/p99-captures", isDirectory: true)
    }

    private func fixtures(model: AppModel) -> [Scene] {
        let nested = JSONValue.object(["complete": .bool(false), "calls": .array([
            .object(["id": .string("call-01"), "toolName": .string("mcp__calendar__find_events"), "status": .string("completed"), "durationMs": .number(480), "arguments": .object(["query": .string("today")])]),
            .object(["id": .string("call-02"), "toolName": .string("read_mcp_resource"), "status": .string("failed"), "durationMs": .number(82), "arguments": .object(["uri": .string("file:///notes/today")])]),
            .object(["id": .string("call-03"), "toolName": .string("display"), "status": .string("completed"), "durationMs": .number(930), "arguments": .object(["title": .string("Schedule")])])
        ])])
        let display = JSONValue.object(["tronNested": .object(["complete": .bool(true), "display": .array([
            .object(["title": .string("Schedule preview"), "mimeType": .string("image/png"), "artifactId": .string("artifact-01")])
        ]), "browserLiveViews": .array([])])])
        let codemode = tool("codemode", request: .object(["code": .string("const events = await tools.calendar.find_events({ query: 'today' });\nconsole.log(events);\nawait tools.display({ title: 'Schedule' });")]), response: nil, content: "Found 3 events for today.\n• Design review · 10:00\n• Planning · 13:30\n• Demo · 16:00", nestedCalls: nested, details: display, usage: .object(["cost": .object(["total": .number(0.0125)])]))

        let views: [Scene] = [
            scene("mcp-servers-global", MCPServersSettingsView(projectCWD: nil).environment(model)),
            scene("mcp-servers-project", MCPServersSettingsView(projectCWD: "/fixture/trusted-project", initialScope: "project").environment(model)),
            scene("mcp-add-server-http", MCPAddServerPresentationEvidence(transport: "http", url: "https://mcp.example.test", command: "", validationMessage: nil)),
            scene("mcp-add-server-stdio", MCPAddServerPresentationEvidence(transport: "stdio", url: "", command: "", validationMessage: nil)),
            scene("extensions-codemode-tools", ExtensionsSettingsView(projectCWD: nil).environment(model)),
            scene("provider-typesafe", ProvidersSettingsView(sessionID: nil).environment(model)),
            scene("tool-codemode", ToolDetailSheet(tool: codemode, density: .expanded)),
            scene("tool-codemode-continuation", ToolDetailSheet(tool: codemode, density: .expanded)),
            scene("tool-mcp-text", ToolDetailSheet(tool: tool("mcp__calendar__find_events", request: .object(["query": .string("today")]), response: .object(["content": .string("Found 3 events for today.")]), content: "Found 3 events for today."), density: .expanded)),
            scene("tool-mcp-image", ToolDetailSheet(tool: tool("mcp__gallery__get_image", request: .object(["item": .string("sunset")]), response: .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("fixture-image")])])]), content: "Image result · image/png"), density: .expanded)),
            scene("tool-mcp-structured", ToolDetailSheet(tool: tool("mcp__inventory__lookup", request: .object(["sku": .string("A-104")]), response: .object(["structuredContent": .object(["available": .bool(true), "quantity": .number(12)])]), content: ""), density: .expanded)),
            scene("tool-mcp-error", ToolDetailSheet(tool: tool("mcp__calendar__delete_event", request: .object(["eventId": .string("evt-19")]), response: .object(["content": .string("Permission denied by calendar server")]), content: "Permission denied by calendar server", error: true, subtitle: "Failed"), density: .expanded)),
            scene("tool-search", ToolDetailSheet(tool: tool("tool_search", request: .object(["query": .string("calendar events")]), response: .object(["content": .string("Loaded tools: calendar/find_events, calendar/create_event")]), content: "Loaded tools: calendar/find_events, calendar/create_event"), density: .expanded)),
            scene("tool-read-mcp-resource", ToolDetailSheet(tool: tool("read_mcp_resource", request: .object(["uri": .string("file:///notes/today")]), response: .object(["contents": .array([.object(["text": .string("Team notes for today")])])]), content: "Team notes for today"), density: .expanded)),
            scene("tool-technical-details", ToolTechnicalDetailsSheet(tool: tool("mcp__calendar__find_events", request: .object(["query": .string("today")]), response: .object(["content": .string("Found 3 events")]), content: "Found 3 events"), presentation: ToolDetailPresentation(tool: tool("mcp__calendar__find_events", request: .object(["query": .string("today")]), response: .object(["content": .string("Found 3 events")]), content: "Found 3 events")))),
            scene("tool-picker", pickerFixture()),
            scene("tool-chips", VStack(alignment: .leading, spacing: 10) {
                Text("Recent tools").font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronTextPrimary)
                ToolCard(data: codemode, onOpenDetails: { _ in })
                ToolCard(data: tool("mcp__calendar__find_events", request: .object(["query": .string("today")]), response: .object(["content": .string("Found 3 events")]), content: "Found 3 events"), onOpenDetails: { _ in })
                ToolCard(data: tool("tool_search", request: .object(["query": .string("calendar events")]), response: .object(["content": .string("Loaded tools")]), content: "Loaded tools"), onOpenDetails: { _ in })
                ToolCard(data: tool("read_mcp_resource", request: .object(["uri": .string("file:///notes/today")]), response: .object(["contents": .array([])]), content: "Team notes"), onOpenDetails: { _ in })
            }.padding(18).environment(model)),
            scene("routed-physical-model", settingsGroup("Assistant · GPT-6.1 Sol", accent: .tronCyan) {
                serverRow("Selected model", state: "Atlas Router · Virtual model", icon: "arrow.trianglehead.branch", detail: "Routed this response to openai/gpt-6.1-sol")
                serverRow("Response model", state: "GPT-6.1 Sol", icon: "cpu", detail: "OpenAI · 272K context")
                Text("This reply used the routed physical model.").font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
            })
        ]
        // Details ensure an image and structured-only MCP payload remain behind
        // the same generic presentation path as text and error results.
        return views
    }

    private func pickerFixture() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools").font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronSessionTeal)
            ForEach([("Calendar", "find_events", "mcp__calendar__find_events", "codemode"), ("Calendar", "create_event", "mcp__calendar__create_event", "direct"), ("Files", "read_file", "read", "direct"), ("Browser", "search", "agent_browser_search", "hidden")], id: \.2) { group, title, name, exposure in
                HStack(spacing: 10) {
                    Image(systemName: exposure == "hidden" ? "circle" : "checkmark.circle.fill").foregroundStyle(Color.tronSessionTeal)
                    VStack(alignment: .leading, spacing: 3) { Text(title).font(TronTypography.bodySM); Text("\(name) · \(exposure)").font(TronTypography.code(size: TronTypography.sizeSecondary)).foregroundStyle(Color.tronTextSecondary).lineLimit(1) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).tronScrollSurface(accent: .tronSessionTeal)
            }
        }.padding(18).background(Color.tronBackground)
    }

    private func scene<V: View>(_ id: String, _ view: V) -> Scene { Scene(id: id, content: AnyView(view)) }
    private func settingsGroup<Content: View>(_ title: String, accent: Color, @ViewBuilder content: () -> Content) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) { TronSettingsGroup(title, accent: accent, surfaceStyle: .glass, content: content) }.padding(20) }.tronScrollEdgeChrome().tronSettingsVisualTheme(accent: accent)
    }
    private func serverRow(_ title: String, state: String, icon: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.tronCyan).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(TronTypography.bodySM); Text(state).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary); Text(detail).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted) }
        }.padding(12)
    }

    private func respondToHostedFixtures(_ socket: ScriptedGatewaySocket) async {
        var handled = Set<String>()
        while !Task.isCancelled {
            for frame in await socket.sentFrames() {
                guard let value = try? JSONDecoder.gateway.decode(JSONValue.self, from: frame),
                      let object = value.objectValue,
                      let method = object["method"]?.stringValue,
                      let id = object["id"]?.stringValue,
                      handled.insert(id).inserted else { continue }
                let result: JSONValue
                switch method {
                case "mcp.list":
                    let fixtureURL = URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent("Fixtures/mcp-list-cli.json")
                    result = (try? JSONDecoder.gateway.decode(JSONValue.self, from: Data(contentsOf: fixtureURL))) ?? .object(["servers": .array([]), "errors": .array([])])
                case "provider.list":
                    result = .object(["providers": .array([.object(["id": .string("openai"), "name": .string("OpenAI"), "configured": .bool(false), "usageSupported": .bool(false), "localOnly": .bool(false), "authMethods": .array([.string("api-key")]), "modelCount": .number(0)])])])
                case "model.list": result = .object(["models": .array([]), "nextCursor": .null])
                case "packages.list":
                    result = .object(["packages": .array([]), "resources": .object(["extensions": .array([]), "skills": .array([]), "prompts": .array([]), "themes": .array([])])])
                case "packages.checkUpdates": result = .object(["updates": .array([])])
                case "modules.list": result = .object(["modules": .array([])])
                case "settings.get":
                    let defaults: [String: JSONValue] = [
                        "extensions": .array([]),
                        "defaultTools": .array([.string("+codemode"), .string("+tool_search")]),
                        "codemode": .object(["mode": .string("on")]),
                    ]
                    result = .object(["documents": .object(["global": .object(defaults), "project": .object(defaults)]), "effective": .object(["defaultTools": .array([.string("+codemode"), .string("+tool_search")]), "codemode": .object(["mode": .string("on")])])])
                default: continue
                }
                let response = JSONValue.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result])
                if let data = try? JSONEncoder.gateway.encode(response) { await socket.enqueue(data) }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    private func tool(_ name: String, request: JSONValue?, response: JSONValue?, content: String, nestedCalls: JSONValue? = nil, details: JSONValue? = nil, usage: JSONValue? = nil, error: Bool = false, subtitle: String = "Completed") -> ChatToolPresentation {
        ChatToolPresentation(id: "fixture-\(name)", title: name, toolName: name, subtitle: subtitle, request: request, response: response, content: content, fallbackContent: nil, nestedCalls: nestedCalls, details: details, usage: usage, error: error, startedAt: "2026-09-30T10:00:00Z", completedAt: "2026-09-30T10:00:01Z", durationMs: 930, lastProgressAt: "2026-09-30T10:00:01Z", progressSequence: 2)
    }
}

@MainActor
private struct MCPAddServerPresentationEvidence: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var serverName = "calendar"
    @State private var transport: String
    @State private var url: String
    @State private var command: String
    @State private var args = "--read-only"
    @State private var bearerToken = "fixture-bearer-token"

    init(transport: String, url: String, command: String, validationMessage: String?) {
        _transport = State(initialValue: transport)
        _url = State(initialValue: url)
        _command = State(initialValue: command)
        self.validationMessage = validationMessage
    }

    private let validationMessage: String?

    var body: some View {
        MCPAddServerForm(
            serverName: $serverName,
            transport: $transport,
            url: $url,
            command: $command,
            args: $args,
            bearerToken: $bearerToken,
            error: validationMessage,
            working: false,
            onAdd: { }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
        .environment(\.colorScheme, colorScheme)
    }
}

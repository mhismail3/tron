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
    func captureConformanceFixtures() throws {
        let scenes = fixtures()
        try FileManager.default.createDirectory(at: Self.captureDirectory, withIntermediateDirectories: true)
        var artifacts: [String] = []
        for scene in scenes {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    let suffix = size == .large ? "std" : "ax"
                    let name = "\(scene.id)-\(scheme == .light ? "light" : "dark")-\(suffix)"
                    let view = scene.content
                        .frame(width: 390, height: 844, alignment: .top)
                        .background(Color.tronBackground)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                    let image = try renderHosted(view, size: CGSize(width: 390, height: 844), dynamicTypeSize: size, scrollToBottom: scene.id == "tool-codemode-continuation")
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
        #expect(scenes.map(\.id).contains("tool-codemode"))
    }

    private func renderHosted<V: View>(_ view: V, size: CGSize, dynamicTypeSize: DynamicTypeSize, scrollToBottom: Bool = false) throws -> UIImage {
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

    private func fixtures() -> [Scene] {
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
            scene("mcp-servers-global", settingsGroup("MCP Servers · Global", accent: .tronCyan) {
                serverRow("calendar", state: "Connected · 5 tools · codemode", icon: "checkmark.circle.fill", detail: "Global configuration")
                serverRow("linear", state: "Needs sign-in · 3 tools", icon: "person.crop.circle.badge.exclamationmark", detail: "OAuth required")
                serverRow("weather", state: "Failed · 0 tools", icon: "exclamationmark.triangle.fill", detail: "stderr: spawn weather-mcp ENOENT")
                serverRow("local-files", state: "Disabled · 4 tools", icon: "pause.circle.fill", detail: "Exposure: hidden")
            }),
            scene("mcp-servers-project", settingsGroup("MCP Servers · Trusted Project", accent: .tronCyan) {
                Text("Project scope · ~/Projects/atlas").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                serverRow("docs", state: "Connected · 2 tools · codemode", icon: "checkmark.circle.fill", detail: "Project configuration")
            }),
            scene("mcp-server-detail", settingsGroup("calendar", accent: .tronCyan) {
                serverRow("Status", state: "Connected", icon: "checkmark.circle.fill", detail: "5 tools · codemode exposure")
                serverRow("Transport", state: "Streamable HTTP", icon: "network", detail: "https://mcp.example.test")
                serverRow("Scope", state: "Global", icon: "globe", detail: "Pi mcp.json")
            }),
            scene("mcp-add-server", settingsGroup("Add MCP Server", accent: .tronCyan) {
                fixtureField("Server name", "calendar")
                fixtureField("Transport", "HTTP")
                fixtureField("Endpoint", "https://mcp.example.test")
                action("Add Server", accent: .tronCyan)
            }),
            scene("extensions-codemode-tools", settingsGroup("Pi Built-ins", accent: .tronCyan) {
                serverRow("codemode", state: "Enabled", icon: "chevron.left.forwardslash.chevron.right", detail: "Execute bounded tool scripts")
                serverRow("tool_search", state: "Enabled", icon: "magnifyingglass", detail: "Find additional tools")
                serverRow("mcp", state: "Enabled", icon: "server.rack", detail: "MCP servers are available")
                serverRow("Default tools", state: "+codemode · +tool_search", icon: "wrench.and.screwdriver", detail: "Codemode: On")
            }),
            scene("provider-typesafe", settingsGroup("TypeSafe (classifier)", accent: .tronCyan) {
                Text("Classifier provider · no chat models").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                fixtureField("API key", "••••••••••••••••")
                action("Save API Key", accent: .tronCyan)
            }),
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
                chip("chevron.left.forwardslash.chevron.right", "Codemode", "3 calls · completed", summary: "Found 3 events")
                chip("network", "calendar/find_events", "Completed · 930ms", summary: "today")
                chip("magnifyingglass", "Search tools", "Completed · 210ms", summary: "calendar events")
                chip("doc.text", "Read MCP resource", "Completed · 120ms", summary: "Team notes")
            }.padding(18)),
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
        ScrollView { VStack(alignment: .leading, spacing: 16) { TronSettingsGroup(title, detail: "Tron · Tools & Extensions", accent: accent, surfaceStyle: .glass, content: content) }.padding(20) }.tronScrollEdgeChrome().tronSettingsVisualTheme(accent: accent)
    }
    private func serverRow(_ title: String, state: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(icon.contains("exclamation") ? Color.tronError : Color.tronCyan).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary); Text(state).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary); Text(detail).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 4)
            Image(systemName: "ellipsis.circle").foregroundStyle(Color.tronTextSecondary)
        }.padding(12)
    }
    private func chip(_ icon: String, _ title: String, _ detail: String, summary: String) -> some View {
        ChatCompactPillSurface(tone: ChatSemanticPillRole.tool.tone, material: .glass, interactive: true) {
            ChatCompactPillLabel(icon: icon, title: title, detail: detail, tone: ChatSemanticPillRole.tool.tone, iconSize: ChatCompactPillLayoutPolicy.toolIconSize) {
                Text(summary).font(TronTypography.sans(size: TronTypography.sizeSecondary)).foregroundStyle(Color.tronTextSecondary).lineLimit(1)
            }
        }
    }

    private func fixtureField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary); Text(value).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).frame(maxWidth: .infinity, alignment: .leading).padding(11).tronGlassSurface(accent: .tronCyan, tintOpacity: 0.07) }
    }
    private func action(_ label: String, accent: Color) -> some View { Text(label).font(TronTypography.buttonSM).foregroundStyle(accent).frame(maxWidth: .infinity).padding(12).tronGlassSurface(accent: accent, tintOpacity: 0.10) }
    private func tool(_ name: String, request: JSONValue?, response: JSONValue?, content: String, nestedCalls: JSONValue? = nil, details: JSONValue? = nil, usage: JSONValue? = nil, error: Bool = false, subtitle: String = "Completed") -> ChatToolPresentation {
        ChatToolPresentation(id: "fixture-\(name)", title: name, toolName: name, subtitle: subtitle, request: request, response: response, content: content, fallbackContent: nil, nestedCalls: nestedCalls, details: details, usage: usage, error: error, startedAt: "2026-09-30T10:00:00Z", completedAt: "2026-09-30T10:00:01Z", durationMs: 930, lastProgressAt: "2026-09-30T10:00:01Z", progressSequence: 2)
    }
}

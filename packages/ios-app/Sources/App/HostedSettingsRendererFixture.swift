#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// The generic settings renderer over a FIXTURE schema (gateway
/// docs/settings-model.md F1, 7.5): a section, a subgroup, a key, a control and
/// a badge kind this app has never been told about render from served data
/// alone. The socket answers `settings.resolve`, `settings.options` and
/// `settings.change` the way the Gateway does, including a dry-run refusal.
@MainActor
struct HostedSettingsRendererFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var applied = 0
    @State private var thinkingOptions = -1
    private let socket = HostedSettingsRendererSocket()
    private let profile: GatewayProfile

    init() {
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        profile = GatewayProfile(id: "settings-renderer-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        try! profiles.save(profile, token: "fixture-token")
        _model = State(initialValue: AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { [socket] _ in socket }),
            profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "settings-renderer-fixture"))))
    }

    var body: some View {
        NavigationStack {
            if ready {
                Group {
                    if ProcessInfo.processInfo.arguments.contains("-tron-mac-settings-fixture") {
                        SettingsView()
                    } else {
                        SettingsRendererView(target: .object(["kind": .string("mac")]), writeLayer: "mac")
                            .tronNavigationTitle("Settings")
                    }
                }
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Text("applied:\(applied)").accessibilityIdentifier("fixture.settings-renderer-applied")
                            Text("thinking-options:\(thinkingOptions)").accessibilityIdentifier("fixture.settings-renderer-thinking-options")
                        }
                        .font(.caption2)
                        .opacity(0.6)
                    }
            } else if let error { Text(error) }
        }
        .environment(model)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-settings-renderer-dark") ? .dark : .light)
        .tronPresentation()
        .tronSettingsLayout()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                ready = true
            } catch { self.error = String(describing: error) }
        }
        .task {
            while !Task.isCancelled {
                (applied, thinkingOptions) = await socket.counters()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private actor HostedSettingsRendererSocket: GatewaySocketConnection {
    private let sourceActions = ProcessInfo.processInfo.arguments.contains("-settings-renderer-source-actions")
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    // The fixture's stores: one Mac layer over built-ins.
    private var model = "pro"
    private var thinking = "high"
    private var retries = 6
    private var invalidValue = ""
    private var transport = "sse"
    private var blockImages = false
    private var focusMode = "calm"
    private var hasSecret = false
    private var paths = ["alpha", "beta"]
    private var applied = 0
    private var thinkingOptions = -1

    func counters() -> (Int, Int) { (applied, thinkingOptions) }
    func resume() async { }
    func ping() async throws { }

    func send(_ data: Data) async throws {
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let id = frame.objectValue?["id"]?.stringValue, let method = frame.objectValue?["method"]?.stringValue else { return }
        let params = frame.objectValue?["params"]?.objectValue ?? [:]
        let result: JSONValue
        switch method {
        case "settings.resolve": result = resolution()
        case "settings.options": result = try options(key: params["key"]?.stringValue ?? "", query: params["query"]?.stringValue, cursor: params["cursor"]?.stringValue)
        case "settings.change": result = try change(params)
        default: result = .object([:])
        }
        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    private var modelName: String { model == "pro" ? "Fixture Pro" : "Fixture Lite" }

    private func resolution() -> JSONValue {
        let keys: [JSONValue] = [
            key("model.ref", group: "model", value: .object(["provider": .string("fixture"), "id": .string(model)]), display: modelName,
                layer: "mac", badges: sourceActions ? [.object([
                    "kind": .string("source"), "label": .string("Fixture source"),
                    "action": .object(["kind": .string("useCurrentDefault"), "label": .string("Use the current default")]),
                ]), .object([
                    "kind": .string("future"), "label": .string("Future source"),
                    "action": .object(["kind": .string("futureAction"), "label": .string("Unsupported action")]),
                ])] : [], presentation: presentation("Model", "The model new chats start with.", 10, "essential", "catalog",
                    extra: ["optionsSource": .object(["name": .string("catalog.models"), "dependsOn": .array([])])])),
            key("model.thinking", group: "model", value: model == "pro" ? .string(thinking) : .string("off"),
                display: model == "pro" ? thinking.capitalized : "Off", presentation: presentation("Thinking", "How much the model reasons.", 20,
                    "essential", "choice", extra: ["valueKind": .string("orderedChoice"), "optionsSource": .object(["name": .string("catalog.thinkingLevels"),
                                                                              "dependsOn": .array([.string("model.ref")])])])),
            key("context.images.block", group: "context", value: .bool(blockImages), display: blockImages ? "On" : "Off",
                presentation: presentation("Block images", "Images are not sent to the model.", 10, "essential", "toggle")),
            key("run.retry.maxRetries", group: "run", subgroup: "Retry", value: .number(Double(retries)), display: "\(retries) retries",
                layer: "mac", presentation: presentation("Retries", "How many times a failed request is retried.", 10, "essential", "number",
                    extra: ["range": .object(["min": .number(0), "max": .number(100), "unit": .string("retries")]),
                            "optionsSource": .object(["name": .string("fixture.retryRange"), "dependsOn": .array([])])])),
            key("run.futureNumber", group: "run", value: .number(1), display: "Future numeric value",
                presentation: presentation("Future number", "An unsupported numeric range remains visible.", 30, "advanced", "number",
                    extra: ["range": .object(["min": .number(0), "max": .number(1e30)])])),
            key("lab.invalidValue", group: "lab", value: .string(invalidValue), display: invalidValue.isEmpty ? "Ready" : invalidValue,
                presentation: presentation("Validation", "A fixture value used to prove Gateway refusal.", 5, "essential", "text")),
            key("run.transport", group: "run", value: .string(transport), display: transport == "sse" ? "Server-sent events" : "WebSocket",
                presentation: presentation("Transport", "How requests reach the provider.", 20, "advanced", "choice",
                    extra: ["options": .array([choice("sse", "Server-sent events"), choice("websocket", "WebSocket")])])),
            key("lab.focusMode", group: "lab", subgroup: "Experiments", value: .string(focusMode), display: focusMode.capitalized,
                badges: [.object(["kind": .string("sparkle"), "label": .string("New")])],
                presentation: presentation("Focus mode", "A choice this app was never told about.", 10, "essential", "choice",
                    extra: ["options": .array([choice("calm", "Calm"), choice("deep", "Deep")])])),
            key("lab.palette", group: "lab", subgroup: "Experiments", value: .string("teal"), display: "Teal",
                presentation: presentation("Palette", "A control this app does not implement.", 20, "advanced", "colorWheel")),
            key("lab.paths", group: "lab", value: .array(paths.map { .string($0) }), display: paths.joined(separator: ", "),
                presentation: presentation("Paths", "Ordered search locations.", 25, "advanced", "list",
                    extra: ["valueKind": .string("stringList")])),
            key("lab.password", group: "lab", value: nil, display: hasSecret ? "Set" : "Not set",
                presentation: presentation("Password", "Write-only replacement.", 26, "advanced", "secret",
                    extra: ["redacted": .bool(true)])),
            key("lab.secretToken", group: "lab", value: nil, display: "Set",
                presentation: presentation("Token", "A secret this app cannot edit yet.", 30, "advanced", "readOnly",
                    extra: ["note": .string("Update Tron to edit"), "redacted": .bool(true)])),
        ]
        let sections: [JSONValue] = [
            section("model", "Model", 10, essential: [("Model", modelName), ("Thinking", model == "pro" ? thinking.capitalized : "Off")],
                    overrides: [("Model", modelName)]),
            section("context", "Context", 20, essential: [("Block images", blockImages ? "On" : "Off")]),
            section("tools", "Tools", 30, essential: []),
            section("permissions", "Permissions", 40, essential: []),
            section("accounts", "Accounts", 60, essential: []),
            section("sources", "Sources", 70, essential: []),
            section("setup", "Setup", 80, essential: []),
            section("run", "Run", 50, essential: [("Retries", "\(retries) retries")], overrides: [("Retries", "\(retries) retries")],
                    pending: true, recent: true),
            section("lab", "Lab", 95, essential: [("Focus mode", focusMode.capitalized)]),
        ]
        return .object(["target": .object(["kind": .string("mac")]), "layers": .array([.string("mac"), .string("builtin")]),
                        "renderer": .object(["version": .number(1)]), "keys": .array(keys), "sections": .array(sections),
                        "diagnostics": .array([])])
    }

    private func options(key: String, query: String?, cursor: String?) throws -> JSONValue {
        switch key {
        case "model.ref":
            let entries = [("pro", "Fixture Pro"), ("lite", "Fixture Lite"), ("page", "Fixture Page Two")]
                .filter { query?.isEmpty != false || $0.1.localizedCaseInsensitiveContains(query!) }
            let offset = Int(cursor ?? "0") ?? 0
            let page = Array(entries.dropFirst(offset).prefix(2))
            var result: [String: JSONValue] = ["key": .string(key), "source": .string("catalog.models"), "dependsOn": .array([]),
                "options": .array(page.map { id, label in
                    .object(["value": .object(["provider": .string("fixture"), "id": .string(id)]), "label": .string(label), "detail": .string("fixture")])
                })]
            if offset + page.count < entries.count { result["nextCursor"] = .string(String(offset + page.count)) }
            return .object(result)
        case "run.retry.maxRetries":
            return .object(["key": .string(key), "source": .string("fixture.retryRange"), "dependsOn": .array([]),
                            "options": .array([]), "range": .object(["min": .number(0), "max": .number(10),
                            "step": .number(2), "unit": .string("retries")])])
        case "model.thinking":
            // A model without reasoning offers no levels.
            let levels = model == "pro" ? [("off", "Off"), ("low", "Low"), ("medium", "Medium"), ("high", "High")] : []
            thinkingOptions = levels.count
            return .object(["key": .string(key), "source": .string("catalog.thinkingLevels"), "dependsOn": .array([.string("model.ref")]),
                            "options": .array(levels.map { choice($0.0, $0.1) })])
        default:
            throw GatewayFailure(code: "invalid_request", message: "Unknown setting \(key)", retryable: false, details: nil)
        }
    }

    private func change(_ params: [String: JSONValue]) throws -> JSONValue {
        let change = params["changes"]?.arrayValue?.first?.objectValue ?? [:]
        let key = change["key"]?.stringValue ?? ""
        let value = change["value"]
        let dryRun = params["dryRun"]?.boolValue == true
        // Validation is the Gateway's: the client holds no copy of a key's rules.
        if key == "lab.invalidValue", value?.stringValue == "rejected" {
            return .object(["dryRun": .bool(true), "status": .string("applied"), "tier": .string("quiet"), "changes": .array([.object([
                "changeId": .string(""), "key": .string(key), "layer": .string("mac"), "status": .string("failed"), "tier": .string("quiet"),
                "error": .object(["code": .string("invalid_request"), "message": .string("Fixture value rejected")]),
            ])])])
        }
        if !dryRun {
            switch key {
            case "model.ref": model = value?.objectValue?["id"]?.stringValue ?? (sourceActions && change["op"]?.stringValue == "unset" ? "lite" : model)
            case "model.thinking": thinking = value?.stringValue ?? thinking
            case "run.retry.maxRetries": retries = value?.intValue ?? retries
            case "lab.invalidValue": invalidValue = value?.stringValue ?? invalidValue
            case "run.transport": transport = value?.stringValue ?? transport
            case "context.images.block": blockImages = value?.boolValue ?? blockImages
            case "lab.focusMode": focusMode = value?.stringValue ?? focusMode
            case "lab.paths": paths = value?.arrayValue?.compactMap(\.stringValue) ?? []
            case "lab.password": hasSecret = value?.stringValue?.isEmpty == false
            default: break
            }
            applied += 1
        }
        return .object([
            "status": .string("applied"), "tier": .string("quiet"),
            "changes": .array([.object(["changeId": .string(dryRun ? "" : "change-\(applied)"), "key": .string(key),
                                        "layer": .string("mac"), "status": .string("applied"), "tier": .string("quiet")])]),
        ].merging(dryRun ? ["dryRun": .bool(true)] : [:]) { $1 })
    }

    private func key(_ id: String, group: String, subgroup: String? = nil, value: JSONValue?, display: String, layer: String = "builtin",
                     badges: [JSONValue] = [], presentation: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "display": .string(display), "layer": .string(layer), "applied": .bool(true),
            "layers": .array([.object(["layer": .string("mac")])]),
            "badges": .array([.object(["kind": .string("layer"), "label": .string(layer == "mac" ? "Mac" : "Built-in")])] + badges),
            "presentation": presentation,
        ]
        if let subgroup { object["subgroup"] = .string(subgroup) }
        if let value { object["value"] = value }
        return .object(object)
    }

    private func presentation(_ label: String, _ help: String, _ order: Int, _ importance: String, _ control: String,
                              extra: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "label": .string(label), "help": .string(help), "order": .number(Double(order)), "importance": .string(importance),
            "control": .string(control), "valueKind": .string("fixture"),
        ].merging(extra) { $1 })
    }

    private func choice(_ value: String, _ label: String) -> JSONValue {
        .object(["value": .string(value), "label": .string(label)])
    }

    private func section(_ id: String, _ title: String, _ order: Int, essential: [(String, String)], overrides: [(String, String)] = [],
                         pending: Bool = false, recent: Bool = false) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "order": .number(Double(order)), "summary": .object([
            "essential": .array(essential.map { .object(["key": .string($0.0), "label": .string($0.0), "display": .string($0.1)]) }),
            "overrides": .array(overrides.map { .object(["key": .string($0.0), "label": .string($0.0), "display": .string($0.1),
                                                          "layer": .string("mac"), "layerLabel": .string("Mac")]) }),
            "pending": .array(pending ? [.object(["requestId": .string("fixture-request"), "requester": .string("Home"),
                                                  "labels": .array([.string("Transport")])])] : []),
            "recent": .array(recent ? [.object(["changeId": .string("fixture-change"), "key": .string("run.retry.maxRetries"),
                                                "label": .string("Retries"), "actor": .string("Home"),
                                                "reason": .string("The provider is flaky today"), "at": .string("2026-01-01T00:00:00.000Z")])] : []),
            "moreRecent": .number(pending ? 2 : 0),
        ])])
    }

    private func enqueue(_ frame: JSONValue) throws {
        let data = try JSONEncoder.gateway.encode(frame)
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { pending.append(data) }
    }

    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
}
#endif

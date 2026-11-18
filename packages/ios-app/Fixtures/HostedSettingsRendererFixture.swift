#if HOSTED_TEST
import SwiftUI
import TronMobileCore

@MainActor
struct HostedSettingsRendererFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var activity = PresentationActivityCoordinator()
    @State private var nestedSettings = false
    @State private var heldPreviews = 0
    @State private var error: String?
    @State private var applied = 0
    @State private var providerOperations = ""
    private let socket = HostedSettingsRendererSocket()
    private let profile: GatewayProfile

    init() {
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        profile = GatewayProfile(id: "settings-renderer-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        try! profiles.save(profile, token: "fixture-token")
        if HostedLaunch.arguments.contains("-settings-expanded-review") {
            try! profiles.save(GatewayProfile(id: "review-offline", label: "Workshop Mac", host: "offline.test", port: 9847,
                machineId: "review-offline-machine",
                machineGroupID: HostedLaunch.arguments.contains("-settings-paired-offline") ? "workshop-host" : nil,
                deviceId: "review-offline-device"), token: "fixture-token", selecting: false)
            if HostedLaunch.arguments.contains("-settings-paired-offline") {
                try! profiles.save(GatewayProfile(id: "review-studio", label: "Studio Mac", host: "studio.test", port: 9847,
                    machineId: "review-studio-machine", machineGroupID: "studio-host", deviceId: "studio-device"),
                    token: "fixture-token", selecting: false)
            }
        }
        let model = AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { [socket] _ in socket }),
            profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "settings-renderer-fixture")))
        model.defaultWorkspace = "/fixture/projects"
        _model = State(initialValue: model)
    }

    var body: some View {
        TronPresentationSurface(id: "fixture.settings-renderer") { fixtureContent }
            .environment(\.tronPresentationActivityCoordinator, activity)
    }

    private var providerReview: some View {
        ScrollView {
            TronSettingsGroup("Configured", accent: .tronPurple, surfaceStyle: .glass) {
                ForEach(["openai-codex", "opencode-go"], id: \.self) { id in
                    ProviderSetupRow(surfaceStyle: .grouped, provider: try! JSONDecoder.gateway.decode(ProviderSummary.self, from: Data("""
                        {"id":"\(id)","name":"\(id == "opencode-go" ? "OpenCode Go" : "OpenAI Codex")","configured":true,"authMethods":[],"modelCount":1}
                        """.utf8)), usageSnapshot: try! JSONDecoder.gateway.decode(ProviderUsageSnapshot.self, from: Data("""
                        {"providerId":"\(id)","status":"available","stale":false,"windows":[{"id":"5h","label":"5h","usedPercent":0,"windowSeconds":18000},{"id":"weekly","label":"Weekly","usedPercent":0,"windowSeconds":604800}\(id == "opencode-go" ? ",{\"id\":\"monthly\",\"label\":\"Monthly\",\"usedPercent\":100,\"windowSeconds\":2592000}" : "")],"balances":[]}
                        """.utf8)))
                    if id == "openai-codex" { TronSettingsDivider(accent: .tronPurple) }
                }
            }.padding(20)
        }.tronNavigationTitle("Model Providers", accent: .tronPurple)
    }

    private var controlsReview: some View {
        ScrollView {
            TronSettingsGroup("Mixed controls") {
                TronSettingsRow(icon: "number", title: "Inherited value") {
                    Button {} label: { TronInlineActionLabel("16,384 tokens") }.buttonStyle(.plain)
                        .accessibilityIdentifier("alignment.inherited")
                }
                TronSettingsDivider()
                TronSettingsRow(icon: "slider.horizontal.3", title: "Short value") {
                    Button {} label: { TronInlineActionLabel("—") }.buttonStyle(.plain)
                        .accessibilityIdentifier("alignment.short")
                }
                TronSettingsDivider()
                TronSettingsRow(icon: "slider.horizontal.3", title: "Summary thinking", subtitle: "Value and reset remain independent targets.") {
                    Button {} label: { TronInlineActionLabel("High") }.buttonStyle(.plain)
                        .accessibilityIdentifier("alignment.revert-value")
                }
                .environment(\.tronSettingsRowAccessory, {
                    AnyView(Button {} label: { TronInlineActionLabel("", icon: "arrow.uturn.backward", alignment: .leading) }
                        .buttonStyle(.plain).accessibilityLabel("Revert")
                        .accessibilityIdentifier("alignment.revert"))
                })
                TronSettingsDivider()
                TronSettingsRow(icon: "number", title: "Optional override", subtitle: "Unset uses the same circular control geometry.") {
                    Button {} label: { TronInlineActionLabel("16,384 tokens") }.buttonStyle(.plain)
                        .accessibilityIdentifier("alignment.unset-value")
                }
                .environment(\.tronSettingsRowAccessory, {
                    AnyView(Button {} label: { TronInlineActionLabel("", icon: "minus", alignment: .leading) }
                        .buttonStyle(.plain).accessibilityLabel("Unset")
                        .accessibilityIdentifier("alignment.unset"))
                })
            }
            .padding(20)
        }
        .tronNavigationTitle("Shared controls")
        .tronSettingsLayout()
    }

    private var fixtureContent: some View {
        NavigationStack {
            if ready {
                Group {
                    if HostedLaunch.arguments.contains("-theme-icon-boundary") {
                        HostedThemeIconFixture()
                    } else if let index = HostedLaunch.arguments.firstIndex(of: "-six-ui-surface"),
                       HostedLaunch.arguments.indices.contains(index + 1) {
                        let surface = HostedLaunch.arguments[index + 1]
                        if surface.hasPrefix("worker-") {
                            HostedWorkerToolFixture(surface: surface)
                        } else {
                            HostedSixSmallUIFixture(surface: surface)
                        }
                    } else if HostedLaunch.arguments.contains("-settings-controls-review") {
                        controlsReview
                    } else if HostedLaunch.arguments.contains("-settings-ui-providers") {
                        providerReview
                    } else if HostedLaunch.arguments.contains("-settings-nested") {
                        Button("Open Settings") { nestedSettings = true }
                            .tronManagedSheet(isPresented: $nestedSettings, identity: "fixture.nested-settings") {
                                SettingsView()
                            }
                    } else {
                        SettingsView()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !HostedLaunch.arguments.contains("-settings-alignment-review")
                        && !HostedLaunch.arguments.contains("-settings-controls-review")
                        && !HostedLaunch.arguments.contains("-six-ui-surface") {
                    HStack {
                        Text("applied:\(applied)").accessibilityIdentifier("fixture.settings-renderer-applied")
                        Text("held:\(heldPreviews)").accessibilityIdentifier("fixture.settings-renderer-held")
                        Text("haptics:\(TronHapticsProbe.shared.summary)").accessibilityIdentifier("fixture.haptics")
                        if HostedLaunch.arguments.contains("-settings-provider-actions") {
                            Text(providerOperations).accessibilityIdentifier("fixture.provider-operations")
                        }
                    }
                    .font(.caption2).opacity(0.6)
                    }
                }
            } else if let error { Text(error) }
        }
        .environment(model)
        .preferredColorScheme(HostedLaunch.arguments.contains("-settings-renderer-dark") ? .dark : .light)
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
                applied = await socket.counters()
                heldPreviews = await socket.previewCount()
                providerOperations = await socket.providerOperationSummary()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private actor HostedSettingsRendererSocket: GatewaySocketConnection {
    private var heldPreview: CheckedContinuation<Void, Never>?
    private var previewsHeld = 0
    func previewCount() -> Int { previewsHeld }
    func releasePreview() { heldPreview?.resume(); heldPreview = nil }

    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    private var model = "pro"
    private var activeTools = ["read", "retired"]
    private var thinking = "high"
    private var invalidValue = ""
    private var blockImages = false
    private var focusMode = "calm"
    private var paths = ["alpha", "beta"]
    private var applied = 0
    private var catalogRefreshes = 0
    private var credentialWrites = 0
    func providerOperationSummary() -> String {
        "refresh:\(catalogRefreshes) credentials:\(credentialWrites)"
    }

    func counters() -> Int { applied }
    func resume() async { }
    func ping() async throws { }

    func send(_ data: Data) async throws {
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let id = frame.objectValue?["id"]?.stringValue, let method = frame.objectValue?["method"]?.stringValue else { return }
        let params = frame.objectValue?["params"]?.objectValue ?? [:]
        let result: JSONValue
        if method.hasPrefix("provider.auth.") || method == "provider.logout" { credentialWrites += 1 }
        switch method {
        case "models.refresh":
            guard params["commandId"]?.stringValue != nil, params["force"]?.boolValue == true,
                  params["sessionId"] == nil else {
                throw GatewayFailure(code: "invalid_request", message: "Expected exact global forced refresh command", retryable: false, details: nil)
            }
            catalogRefreshes += 1
            result = .object(["aborted": .bool(false), "errors": .object([:])])
        case "provider.list":
            result = .object(["providers": .array([.object([
                "id": .string("fixture"), "name": .string("Fixture Provider"),
                "configured": .bool(true), "authMethods": .array([]), "modelCount": .number(3)
            ])])])
        case "model.list":
            let models: [JSONValue] = [("pro", "Fixture Pro"), ("lite", "Fixture Lite"), ("page", "Fixture Page Two")].map { id, name in
                .object([
                    "provider": .string("fixture"), "id": .string(id), "name": .string(name),
                    "reasoning": .bool(true), "input": .array([.string("text")]),
                    "contextWindow": .number(8192), "maxTokens": .number(1024),
                    "available": .bool(true), "virtual": .bool(false)
                ])
            }
            result = .object(["models": .array(models), "nextCursor": .null])
        case "gateway.update.config.status":
            result = .object(["schema": .number(1), "kind": .string("tron-gateway-update-config"), "sourceRoot": .string("/fixture/projects"), "updatedAt": .string("2026-10-20T00:00:00Z")])
        case "gateway.update.status":
            result = .object(["state": .string("idle"), "channel": .string("stable"), "candidateAvailable": .bool(false), "rollbackAvailable": .bool(false)])
        case "filesystem.list":
            result = .object(["path": params["path"] ?? .string("/fixture/projects"), "parent": .string("/fixture"), "entries": .array([
                .object(["name": .string("Example"), "path": .string("/fixture/projects/Example"), "kind": .string("directory"), "hidden": .bool(false)])
            ])])
        case "session.workspace.inspect" where HostedLaunch.arguments.contains("-six-ui-surface"):
            result = .object(["root": .string("/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"), "revision": .string("preview"),
                "repository": .object(["root": .string("/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"),
                    "branch": .null, "head": .string("b8d31a1d12345678"), "detached": .bool(true), "unborn": .bool(false),
                    "dirty": .bool(false), "changes": .array([])])])
        case "session.workspace.list":
            result = .object(["root": .string("/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"),
                "path": .string(""), "parent": .null, "revision": .string("preview"), "entries": .array([])])
        case "trust.inspect": result = .object(["requiresDecision": .bool(false), "effectiveDecision": .bool(true)])
        case "git.inspect": result = .object(["isRepository": .bool(true), "branch": .null, "dirty": .bool(false), "branches": .array([]), "commits": .array([])])
        case "model.recent": result = .object(["models": .array([])])
        case "settings.resolve": result = resolution()
        case "settings.change":
            if HostedLaunch.arguments.contains("-settings-renderer-held-preview"),
               params["dryRun"]?.boolValue == true, previewsHeld == 0 {
                previewsHeld += 1
                await withCheckedContinuation { heldPreview = $0 }
            }
            result = try change(params)
        default: result = .object([:])
        }
        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    private var modelName: String { model == "pro" ? "Fixture Pro" : "Fixture Lite" }

    private let weights: [String: JSONValue] = ["red": .number(2)]

    private func resolution() -> JSONValue {
        if HostedLaunch.arguments.contains("-settings-expanded-review") {
            let rows = [HostedSettingsReviewSchema.key("model.ref[role=chat]", "model", .object(["provider": .string("fixture"), "id": .string("pro")]), "Fixture Model")]
                + HostedSettingsReviewSchema.additionalKeys
                + (HostedLaunch.arguments.contains("-settings-sheet-theme-review") ? HostedSettingsReviewSchema.macTerminalKeys : [])
            if HostedLaunch.arguments.contains("-six-ui-surface") {
                return .object(["keys": .array(rows)])
            }
            let keys = rows.compactMap { value -> JSONValue? in
                guard var row = value.objectValue,
                      row["layers"]?.arrayValue?.contains(where: { $0.objectValue?["layer"]?.stringValue == "global" }) == true else { return nil }
                row["layer"] = .string("global")
                row["layers"] = .array([.object(["layer": .string("global"), "value": row["value"] ?? .null])])
                return .object(row)
            }
            return .object(["keys": .array(keys)])
        }
        if HostedLaunch.arguments.contains("-settings-alignment-review") {
            let keys = [("inherited", "Inherited value", "16,384 tokens", false),
                        ("short", "Short value", "—", false),
                        ("revert", "Owned value", "High", true),
                        ("unset", "Optional override", "16,384 tokens", true)].enumerated().map { index, item -> JSONValue in
                var row = HostedSettingsReviewSchema.key("alignment.\(item.0)", "context", .string(item.2), item.2).objectValue!
                row["overridden"] = .bool(item.3)
                return .object(row)
            }
            return .object(["target": .object(["kind": .string("global")]), "layers": .array([.string("global")]),
                "keys": .array(keys), "diagnostics": .array([])])
        }
        let keys: [JSONValue] = [
            key("model.ref", group: "model", value: .object(["provider": .string("fixture"), "id": .string(model)]), display: modelName,
                set: true),
            key("model.thinking", group: "model", value: model == "pro" ? .string(thinking) : .string("off"),
                display: model == "pro" ? thinking.capitalized : "Off"),
            key("context.images.block", group: "context", value: .bool(blockImages), display: blockImages ? "On" : "Off"),
            key("tools.active", group: "tools", value: .array(activeTools.map(JSONValue.string)), display: activeTools.joined(separator: ", "),
                set: true),
            key("run.retry.maxRetries", group: "run", subgroup: "Retry", value: .number(6), display: "6 retries",
                set: true),
            key("lab.invalidValue", group: "lab", value: .string(invalidValue), display: invalidValue.isEmpty ? "Ready" : invalidValue),
            key("run.transport", group: "run", value: .string("sse"), display: "Server-sent events", set: true),
            key("lab.focusMode", group: "lab", subgroup: "Experiments", value: .string(focusMode), display: focusMode.capitalized,
                badges: [.object(["kind": .string("sparkle"), "label": .string("New")])]),
            key("lab.palette", group: "lab", subgroup: "Experiments", value: .string("teal"), display: "Teal"),
            key("lab.paths", group: "lab", value: .array(paths.map { .string($0) }), display: paths.joined(separator: ", ")),
            key("lab.weights", group: "lab", value: .object(weights), display: weights.keys.sorted().map { "\($0):\(weights[$0]!)" }.joined(separator: ", ")),
            key("lab.secretToken", group: "lab", value: nil, display: "Set"),
        ]
        return .object(["target": .object(["kind": .string("global")]), "layers": .array([.string("global")]),
                        "keys": .array(keys),
                        "diagnostics": .array([])])
    }

    private func change(_ params: [String: JSONValue]) throws -> JSONValue {
        let change = params["changes"]?.arrayValue?.first?.objectValue ?? [:]
        let key = change["key"]?.stringValue ?? ""
        let value = change["value"]
        let dryRun = params["dryRun"]?.boolValue == true
        if key == "lab.invalidValue", value?.stringValue == "rejected" {
            return .object(["dryRun": .bool(true), "status": .string("applied"), "tier": .string("quiet"), "changes": .array([.object([
                "changeId": .string(""), "key": .string(key), "layer": .string("global"), "status": .string("failed"), "tier": .string("quiet"),
                "error": .object(["code": .string("invalid_request"), "message": .string("Fixture value rejected")]),
            ])])])
        }
        if !dryRun {
            switch key {
            case "model.ref": model = value?.objectValue?["id"]?.stringValue ?? (change["op"]?.stringValue == "unset" ? "lite" : model)
            case "model.thinking": thinking = value?.stringValue ?? thinking
            case "lab.invalidValue": invalidValue = value?.stringValue ?? invalidValue
            case "context.images.block": blockImages = value?.boolValue ?? blockImages
            case "tools.active":
                activeTools = value?.arrayValue?.compactMap(\.stringValue) ?? activeTools
            case "lab.focusMode": focusMode = value?.stringValue ?? focusMode
            case "lab.paths": paths = value?.arrayValue?.compactMap(\.stringValue) ?? []
            default: break
            }
            applied += 1
        }
        var outcome: [String: JSONValue] = ["changeId": .string(dryRun ? "" : "change-\(applied)"), "key": .string(key),
            "layer": .string("global"), "status": .string("applied"), "tier": .string("quiet")]
        let review: [String: JSONValue] = dryRun && key == "context.images.block" && HostedLaunch.arguments.contains("-settings-renderer-confirm")
            ? ["review": .object(["digest": .string(String(repeating: "b", count: 64)), "title": .string("Change image delivery"),
                "requiresTap": .bool(true), "reason": .string("Confirm changing image delivery."),
                "items": .array([.object(["label": .string("Block images"), "before": .string("Off"), "after": .string("On")])])])]
            : [:]
        return .object([
            "status": .string("applied"), "tier": .string("quiet"), "changes": .array([.object(outcome)]),
        ].merging(dryRun ? ["dryRun": .bool(true)] : [:]) { $1 }.merging(review) { $1 })
    }

    private func key(_ id: String, group: String, subgroup: String? = nil, value: JSONValue?, display: String,
                     set: Bool = false, badges: [JSONValue] = []) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "display": .string(display), "layer": .string("global"), "applied": .bool(true),
            "overridden": .bool(set),
            "layers": .array([.object(["layer": .string("global")])]),
            "badges": .array(badges),
        ]
        if let subgroup { object["subgroup"] = .string(subgroup) }
        if let value { object["value"] = value }
        return .object(object)
    }

    private func choice(_ value: String, _ label: String) -> JSONValue { .object(["value": .string(value), "label": .string(label)]) }

    private func section(_ id: String, _ title: String, _ order: Int, _ description: String) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "description": .string(description), "order": .number(Double(order))]) }

    private func enqueue(_ frame: JSONValue) throws {
        let data = try JSONEncoder.gateway.encode(frame)
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { pending.append(data) }
    }

    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            let capabilities = HostedLaunch.arguments.contains("-settings-sheet-theme-review")
                ? #"["sessions.v1","gateway-update.v1","restart-supervised.v1"]"# : #"["sessions.v1"]"#
            return Data("""
                {"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":\(capabilities)}
                """.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
}


#endif

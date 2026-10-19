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
    @State private var push = PushNotificationCoordinator(credentials: UIReviewPushStore(), notifications: .live, appAttest: .live, configuration: nil)
    @State private var ready = false
    @State private var activity = PresentationActivityCoordinator()
    @State private var covering = false
    @State private var nestedSettings = false
    @State private var heldPreviews = 0
    @State private var error: String?
    @State private var applied = 0
    @State private var thinkingOptions = -1
    @State private var undos = 0
    @State private var decisions = "decisions:0"
    @State private var toolWrite = "none"
    @State private var providerOperations = ""
    @State private var openedRoute: AppModel.SessionNavigationRoute?
    private let socket = HostedSettingsRendererSocket()
    private let profile: GatewayProfile

    init() {
        if let lastLook = HostedSettingsChangesReview.lastLook ?? (ProcessInfo.processInfo.arguments.contains("-settings-changes") ? "2026-10-10T00:00:00Z" : nil) {
            UserDefaults.standard.set(lastLook, forKey: "settings.changes.lastLookedAt.settings-renderer-fixture.all")
        }
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        profile = GatewayProfile(id: "settings-renderer-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        try! profiles.save(profile, token: "fixture-token")
        if ProcessInfo.processInfo.arguments.contains("-settings-expanded-review") {
            try! profiles.save(GatewayProfile(id: "review-offline", label: "Workshop Mac", host: "offline.test", port: 9847,
                machineId: "review-offline-machine",
                machineGroupID: ProcessInfo.processInfo.arguments.contains("-settings-paired-offline") ? "workshop-host" : nil,
                deviceId: "review-offline-device"), token: "fixture-token", selecting: false)
            if ProcessInfo.processInfo.arguments.contains("-settings-paired-offline") {
                try! profiles.save(GatewayProfile(id: "review-studio", label: "Studio Mac", host: "studio.test", port: 9847,
                    machineId: "review-studio-machine", machineGroupID: "studio-host", deviceId: "studio-device"),
                    token: "fixture-token", selecting: false)
            }
        }
        _model = State(initialValue: AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { [socket] _ in socket }),
            profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "settings-renderer-fixture"))))
    }

    var body: some View {
        TronPresentationSurface(id: "fixture.settings-renderer") { fixtureContent }
            .environment(\.tronPresentationActivityCoordinator, activity)
    }

    /// Production provider rows with the reported three-window payload, without a live account.
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

    /// Capture the shared primitive with both circular glyphs, including Unset.
    /// Production currently exposes reset-to-inherited, not a separate Unset button.
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
                    Button {} label: { TronInlineActionLabel("", icon: "arrow.uturn.backward") }
                        .buttonStyle(.plain).accessibilityLabel("Revert")
                        .accessibilityIdentifier("alignment.revert")
                }
                TronSettingsDivider()
                TronSettingsRow(icon: "number", title: "Optional override", subtitle: "Unset uses the same circular control geometry.") {
                    Button {} label: { TronInlineActionLabel("16,384 tokens") }.buttonStyle(.plain)
                        .accessibilityIdentifier("alignment.unset-value")
                    Button {} label: { TronInlineActionLabel("", icon: "minus") }
                        .buttonStyle(.plain).accessibilityLabel("Unset")
                        .accessibilityIdentifier("alignment.unset")
                }
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
                    if ProcessInfo.processInfo.arguments.contains("-settings-controls-review") {
                        controlsReview
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-alignment-review") {
                        SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "mac", presentation: .section("context"))
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-ui-providers") {
                        providerReview
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-ui-push") {
                        PushNotificationsSettingsView()
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-changes") {
                        SettingsChangesView(scope: ProcessInfo.processInfo.arguments.contains("-settings-changes-session")
                            ? .session("fixture-chat", projectCWD: "/fixture/project") : .all,
                            onOpenSession: { openedRoute = $0 })
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-renderer-held-preview") || ProcessInfo.processInfo.arguments.contains("-settings-renderer-confirm") {
                        // The Context sheet itself, so the fixture's cover control stays reachable.
                        SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "mac", presentation: .section("context"))
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-nested") {
                        Button("Open Settings") { nestedSettings = true }
                            .tronManagedSheet(isPresented: $nestedSettings, identity: "fixture.nested-settings") {
                                SettingsView()
                            }
                    } else {
                        SettingsView()
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if !ProcessInfo.processInfo.arguments.contains("-settings-alignment-review")
                        && !ProcessInfo.processInfo.arguments.contains("-settings-controls-review") {
                    HStack {
                        Text("applied:\(applied)").accessibilityIdentifier("fixture.settings-renderer-applied")
                        Text("held:\(heldPreviews)").accessibilityIdentifier("fixture.settings-renderer-held")
                        if ProcessInfo.processInfo.arguments.contains("-settings-renderer-held-preview") {
                            Button("Cover renderer") { covering = true }
                        }
                        Text("thinking-options:\(thinkingOptions)").accessibilityIdentifier("fixture.settings-renderer-thinking-options")
                        Text("undos:\(undos)").accessibilityIdentifier("fixture.settings-changes-undos")
                        Text(decisions).accessibilityIdentifier("fixture.settings-changes-decisions")
                        if ProcessInfo.processInfo.arguments.contains("-settings-ui-tools-write") {
                            Text(toolWrite).accessibilityIdentifier("fixture.tools-write")
                        }
                        if ProcessInfo.processInfo.arguments.contains("-settings-provider-actions") {
                            Text(providerOperations).accessibilityIdentifier("fixture.provider-operations")
                        }
                        if let openedRoute {
                            Text("owned:\(model.ownsNavigationRoute(openedRoute)):\(openedRoute.sessionID)")
                                .accessibilityIdentifier("fixture.settings-changes-route")
                        }
                    }
                    .font(.caption2).opacity(0.6)
                    }
                }
            } else if let error { Text(error) }
        }
        .tronManagedSheet(isPresented: $covering, identity: "fixture.settings-cover") {
            NavigationStack {
                Button("Release preview") { Task { await socket.releasePreview() } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { covering = false } } }
            }
        }
        .environment(model)
        .environment(push)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-settings-renderer-dark") ? .dark : .light)
        .tronPresentation()
        .tronSettingsLayout()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.pushNotificationReadiness = .ready
                model.pushRegistrationDiagnostic = .complete
                await HostedSettingsChangesReview.prepare(model); ready = true
            } catch { self.error = String(describing: error) }
        }
        .task {
            while !Task.isCancelled {
                (applied, thinkingOptions, undos) = await socket.counters()
                heldPreviews = await socket.previewCount()
                decisions = await socket.decisionSummary()
                toolWrite = await socket.lastToolWrite()
                providerOperations = await socket.providerOperationSummary()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private struct UIReviewPushStore: PushCredentialStoring {
    func load() throws -> PushCredentialDocument? { nil }
    func save(_ document: PushCredentialDocument) throws {}
}

private actor HostedSettingsRendererSocket: GatewaySocketConnection {
    private let sourceActions = ProcessInfo.processInfo.arguments.contains("-settings-renderer-source-actions")
    private var heldPreview: CheckedContinuation<Void, Never>?
    private var previewsHeld = 0
    func previewCount() -> Int { previewsHeld }
    func releasePreview() { heldPreview?.resume(); heldPreview = nil }

    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    // The fixture's stores: one Mac layer over built-ins.
    private var model = "pro"
    private var activeTools = ["read", "retired"]
    private var toolWrite = "none"
    func lastToolWrite() -> String { toolWrite }
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
    private var undos = 0
    private var decided: [String: Bool] = [:]
    private var catalogRefreshes = 0
    private var customReads = 0
    private var customWrites = 0
    private var credentialWrites = 0
    func providerOperationSummary() -> String {
        "refresh:\(catalogRefreshes) custom-read:\(customReads) custom-write:\(customWrites) credentials:\(credentialWrites)"
    }
    func decisionSummary() -> String { "decisions:\(decided.count) approved:\(decided.values.filter { $0 }.count)" }

    func counters() -> (Int, Int, Int) { (applied, thinkingOptions, undos) }
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
        case "models.custom.get":
            customReads += 1
            result = .object(["document": .object(["providers": .object([:])]), "redacted": .bool(false)])
        case "models.custom.put":
            customWrites += 1
            result = .object([:])
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
        case "model.recent": result = .object(["models": .array([])])
        case "settings.resolve": result = resolution()
        case "settings.options": result = try options(key: params["key"]?.stringValue ?? "", cursor: params["cursor"]?.stringValue)
        case "settings.change":
            if ProcessInfo.processInfo.arguments.contains("-settings-renderer-held-preview"),
               params["dryRun"]?.boolValue == true, previewsHeld == 0 {
                previewsHeld += 1
                await withCheckedContinuation { heldPreview = $0 }
            }
            result = try change(params)
        case "settings.history": result = HostedSettingsChangesReview.page(params) ?? historyPage(params)
        case "settings.approvals": result = .object(["requests": .array(approvalRequests())])
        case "settings.decide":
            guard let id = params["requestId"]?.stringValue, params["digest"]?.stringValue == "digest-\(id)",
                  params["commandId"]?.stringValue != nil, let approved = params["approved"]?.boolValue else {
                throw GatewayFailure(code: "invalid_request", message: "Exact decision receipt required", retryable: false, details: nil)
            }
            decided[id] = approved
            result = .object(["status": .string(approved ? "approved" : "declined"), "changes": .array([])])
        case "settings.undo":
            undos += 1
            if ProcessInfo.processInfo.arguments.contains("-settings-undo-refused") {
                let failure: JSONValue = .object(["code": .string("conflict"),
                    "message": .string("The setting changed since; undo would overwrite a newer value"),
                    "retryable": .bool(false), "details": .object([
                        "current": .number(8), "after": .number(6),
                        "display": .object(["current": .string("8 retries"), "after": .string("6 retries")])
                    ])])
                if ProcessInfo.processInfo.arguments.contains("-settings-undo-outcome-refused") {
                    result = .object(["status": .string("applied"), "changes": .array([
                        .object(["key": .string("run.transport"), "status": .string("applied")]), .object([
                        "key": .string("run.retry.maxRetries"), "status": .string("failed"), "error": failure
                    ])])])
                } else {
                    try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(false), "error": failure]))
                    return
                }
            } else {
                result = .object(["status": .string("applied"), "changes": .array([])])
            }
        case "packages.list" where HostedExtensionsReview.enabled: result = HostedExtensionsReview.inventory
        case "packages.checkUpdates" where HostedExtensionsReview.enabled: result = .object(["updates": .array([])])
        default: result = HostedSettingsChangesReview.response(method) ?? .object([:])
        }
        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    private var modelName: String { model == "pro" ? "Fixture Pro" : "Fixture Lite" }

    private func approvalRequests() -> [JSONValue] {
        guard ProcessInfo.processInfo.arguments.contains("-settings-changes-approvals") else { return [] }
        return ["approve", "decline"].filter { decided[$0] == nil }.map { id in
            .object(["requestId": .string(id), "digest": .string("digest-\(id)"),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                "expiresAt": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))),
                "actor": .object(["kind": .string("agent"), "sessionId": .string("fixture-chat")]),
                "target": .object(["kind": .string("mac")]), "requester": .string("Fixture agent"),
                "changes": .array([.object(["changeId": .string("pending-\(id)"), "key": .string("run.retry.maxRetries"),
                    "label": .string("Request \(id)"), "layer": .string("mac"), "op": .string("set"), "tier": .string("approve"),
                    "before": .number(4), "after": .number(6), "display": .object(["before": .string("4 retries"), "after": .string("6 retries")])])])])
        }
    }

    private func historyPage(_ params: [String: JSONValue]) -> JSONValue {
        guard params["key"] != nil || params["cursor"]?.stringValue == "fixture-next" else {
            return .object(["entries": .array([]), "nextCursor": .string("fixture-next")])
        }
        var entries = [historyEntry()]
        if ProcessInfo.processInfo.arguments.contains("-settings-changes-scope") {
            let base = historyEntry().objectValue!
            entries += [
                .object(base.merging(["changeId": .string("project-change"), "layer": .string("project"),
                    "actor": .object(["kind": .string("outside")]),
                    "target": .object(["kind": .string("project"), "cwd": .string("/fixture/project")]),
                    "status": .string("outside")]) { $1 }),
                .object(base.merging(["changeId": .string("foreign-change"),
                    "actor": .object(["kind": .string("agent"), "sessionId": .string("foreign-chat")]),
                    "target": .object(["kind": .string("session"), "sessionId": .string("foreign-chat")])]) { $1 }),
                .object(base.merging(["changeId": .string("ui-change"), "actor": .object(["kind": .string("ui")]),
                    "layer": .string("chat"),
                    "target": .object(["kind": .string("session"), "sessionId": .string("fixture-chat")]),
                    "status": .string("failed")]) { $1 })
            ]
        }
        entries = entries.filter { entry in
            let value = entry.objectValue!
            let actor = value["actor"]?.objectValue?["kind"]?.stringValue
            let requestedActor = params["actor"]?.stringValue
            return (requestedActor == nil || (requestedActor == "agents" ? actor != "ui" : actor == requestedActor))
                && (params["layer"] == nil || params["layer"] == value["layer"])
                && (params["key"] == nil || params["key"] == value["key"])
                && (params["section"] == nil || params["section"] == value["presentation"]?.objectValue?["section"])
                && (params["status"] == nil || params["status"] == value["status"])
        }
        return .object(["entries": .array(entries)])
    }

    private var weights: [String: JSONValue] = ["red": .number(2)]

    private func historyEntry() -> JSONValue {
        // A redacted entry carries no before/after values, so it cannot be undone.
        if ProcessInfo.processInfo.arguments.contains("-settings-changes-redacted") {
            return .object([
                "changeId": .string("fixture-change"), "at": .string("2026-10-11T12:00:00.000Z"),
                "actor": .object(["kind": .string("agent"), "sessionId": .string("fixture-chat")]),
                "target": .object(["kind": .string("mac")]), "layer": .string("mac"),
                "key": .string("run.retry.maxRetries"), "op": .string("set"), "changed": .bool(true), "redacted": .bool(true),
                "tier": .string("quiet"), "status": .string("applied"),
                "presentation": .object(["label": .string("Agent retry count"), "section": .string("run"),
                    "actor": .string("Agent"), "layer": .string("Mac"),
                    "display": .object(["before": .string("Hidden"), "after": .string("Changed")])]),
            ])
        }
        return .object([
            "changeId": .string("fixture-change"), "at": .string("2026-10-11T12:00:00.000Z"),
            "actor": .object(["kind": .string("agent"), "sessionId": .string("fixture-chat")]),
            "target": .object(["kind": .string("mac")]), "layer": .string("mac"),
            "key": .string("run.retry.maxRetries"), "op": .string("set"),
            "before": .number(4), "after": .number(6), "tier": .string("quiet"), "status": .string("applied"),
            "tierBasis": .object(["direction": .string("widen"), "floor": .string("quiet"), "floorSource": .string("code"),
                "web": .bool(false), "risk": .string("quiet"),
                "riskEvaluation": .object(["status": .string("assessed"), "rationale": .string("The deterministic floor is sufficient.")])]),
            "presentation": .object(["label": .string("Agent retry count"), "section": .string("run"),
                "actor": .string("Agent"), "layer": .string("Mac"),
                "display": .object(["before": .string("4 retries"), "after": .string("6 retries")])]),
        ])
    }

    private func resolution() -> JSONValue {
        if ProcessInfo.processInfo.arguments.contains("-settings-expanded-review") {
            let rows = [HostedSettingsReviewSchema.key("model.ref[role=chat]", "model", "Model", .object(["provider": .string("fixture"), "id": .string("pro")]), "Fixture Model", "catalog", essential: true)]
                + HostedSettingsReviewSchema.additionalKeys
                + [HostedSettingsReviewSchema.key("setup.sessionDir", "setup", "Session folder", .string("/workspace/sessions"), "/workspace/sessions", "readOnly", help: "Where chats are stored. Applies after a restart."),
                   HostedSettingsReviewSchema.key("setup.installTelemetry", "setup", "Install telemetry", .bool(false), "Off", "toggle", order: 20)]
            let keys = rows.compactMap { value -> JSONValue? in
                guard var row = value.objectValue,
                      row["layers"]?.arrayValue?.contains(where: { $0.objectValue?["layer"]?.stringValue == "mac" }) == true else { return nil }
                row["layer"] = .string("mac"); row["origin"] = .string("inherited")
                row["layers"] = .array([.object(["layer": .string("mac"), "value": row["value"] ?? .null]), .object(["layer": .string("builtin")])])
                row["badges"] = .array([.object(["kind": .string("layer"), "label": .string("Mac")])])
                if var presentation = row["presentation"]?.objectValue {
                    presentation["editableLayers"] = .array([.string("mac")])
                    if row["key"]?.stringValue == "model.ref[role=chat]" {
                        presentation["valueKind"] = .string("model")
                        presentation["optionsSource"] = .object(["name": .string("catalog.models"), "dependsOn": .array([])])
                    }
                    row["presentation"] = .object(presentation)
                }
                return .object(row)
            }
            return .object(["keys": .array(keys), "sections": .array(HostedSettingsReviewSchema.sections + [
                .object(["id": .string("setup"), "title": .string("Setup"), "order": .number(80)])])])
        }
        if ProcessInfo.processInfo.arguments.contains("-settings-alignment-review") {
            // Match the reported mix: owned automatic/summary overrides beside
            // an inherited branch value, through the actual schema renderer.
            let keys = HostedSettingsReviewSchema.additionalKeys.filter { $0.objectValue?["group"]?.stringValue == "context" }.map { value -> JSONValue in
                guard var row = value.objectValue else { return value }
                if row["key"]?.stringValue == "context.branchSummary.reserveTokens" {
                    row["layer"] = .string("builtin")
                    row["layers"] = .array([.object(["layer": .string("mac")]),
                        .object(["layer": .string("builtin"), "value": row["value"] ?? .null])])
                }
                return .object(row)
            }
            return .object(["target": .object(["kind": .string("mac")]), "layers": .array([.string("mac"), .string("builtin")]),
                "renderer": .object(["version": .number(1)]), "keys": .array(keys),
                "sections": .array(HostedSettingsReviewSchema.sections), "diagnostics": .array([])])
        }
        var keys: [JSONValue] = [
            // A catalog source the app has no dedicated picker for, so the generic
            // paged catalog renders it (real model keys use the shared model picker).
            key("model.ref", group: "model", value: .object(["provider": .string("fixture"), "id": .string(model)]), display: modelName,
                layer: "mac", badges: sourceActions ? [.object([
                    "kind": .string("source"), "label": .string("Fixture source"),
                    "action": .object(["kind": .string("useCurrentDefault"), "label": .string("Use the current default")]),
                ]), .object([
                    "kind": .string("future"), "label": .string("Future source"),
                    "action": .object(["kind": .string("futureAction"), "label": .string("Unsupported action")]),
                ])] : [], presentation: presentation("Model", "The model new chats start with.", 10, "essential", "catalog",
                    extra: ["optionsSource": .object(["name": .string("fixture.catalog"), "dependsOn": .array([])])])),
            key("model.thinking", group: "model", value: model == "pro" ? .string(thinking) : .string("off"),
                display: model == "pro" ? thinking.capitalized : "Off", presentation: presentation("Thinking", "How much the model reasons.", 20,
                    "essential", "choice", extra: ["valueKind": .string("orderedChoice"), "optionsSource": .object(["name": .string("catalog.thinkingLevels"),
                                                                              "dependsOn": .array([.string("model.ref")])])])),
            key("context.images.block", group: "context", value: .bool(blockImages), display: blockImages ? "On" : "Off",
                presentation: presentation("Block images", "Images are not sent to the model.", 10, "essential", "toggle")),
            key("tools.active", group: "tools", value: .array(activeTools.map(JSONValue.string)), display: activeTools.joined(separator: ", "),
                layer: "mac", presentation: presentation("Tools", "Tools available to new chats.", 10, "essential", "checklist",
                    extra: ["optionsSource": .object(["name": .string("catalog.tools"), "dependsOn": .array([])])])),
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
            key("lab.weights", group: "lab", value: .object(weights), display: weights.keys.sorted().map { "\($0):\(weights[$0]!)" }.joined(separator: ", "),
                presentation: presentation("Weights", "Gateway-defined numeric fields.", 26, "advanced", "list",
                    extra: ["valueKind": .string("numberMap"),
                        "options": .array([.object(["value": .string("red"), "label": .string("Red weight")]),
                                           .object(["value": .string("blue"), "label": .string("Blue weight")])]),
                        "range": .object(["min": .number(0), "max": .number(100), "step": .number(1)])])),
            key("lab.password", group: "lab", value: nil, display: hasSecret ? "Set" : "Not set",
                presentation: presentation("Password", "Write-only replacement.", 26, "advanced", "secret",
                    extra: ["redacted": .bool(true)])),
            key("lab.secretToken", group: "lab", value: nil, display: "Set",
                presentation: presentation("Token", "A secret this app cannot edit yet.", 30, "advanced", "readOnly",
                    extra: ["note": .string("Update Tron to edit"), "redacted": .bool(true)])),
        ]
        if HostedExtensionsReview.enabled { keys += HostedExtensionsReview.sourceKeys.map { row in
            key(row.id, group: "sources", subgroup: row.subgroup, value: row.value, display: row.display, layer: "mac",
                presentation: presentation(row.label, row.help, row.order, row.importance, row.control,
                                           extra: ["valueKind": .string("stringList")]))
        } }
        let sections: [JSONValue] = [
            section("model", "Model", 10, "Models, thinking, and context window"),
            section("context", "Context", 20, "Compaction and image handling"),
            section("tools", "Tools", 30, "Available tools, code mode, and shell"),
            section("permissions", "Permissions", 40, "Project trust and agent approvals"),
            section("accounts", "Accounts", 60, "Providers, custom models, and services"),
            section("sources", "Sources", 70, "Packages and how they install"),
            section("setup", "Setup", 80, "Import, session storage, and telemetry"),
            section("run", "Run", 50, "Message delivery, retries, and transport"),
            section("lab", "Lab", 95, "A section this app has never seen"),
        ]
        return .object(["target": .object(["kind": .string("mac")]), "layers": .array([.string("mac"), .string("builtin")]),
                        "renderer": .object(["version": .number(1)]), "keys": .array(keys), "sections": .array(sections),
                        "diagnostics": .array([])])
    }

    private func options(key: String, cursor: String?) throws -> JSONValue {
        switch key {
        case "model.ref":
            let entries = [("pro", "Fixture Pro"), ("lite", "Fixture Lite"), ("page", "Fixture Page Two")]
            let offset = Int(cursor ?? "0") ?? 0
            let page = Array(entries.dropFirst(offset).prefix(2))
            var result: [String: JSONValue] = ["key": .string(key), "source": .string("fixture.catalog"), "dependsOn": .array([]),
                "options": .array(page.map { id, label in
                    .object(["value": .object(["provider": .string("fixture"), "id": .string(id)]), "label": .string(label), "detail": .string("fixture")])
                })]
            if offset + page.count < entries.count { result["nextCursor"] = .string(String(offset + page.count)) }
            return .object(result)
        case "tools.active":
            let definitions: [(String, String, String, String)] = [
                ("read", "Read", "Read file contents from a path.", "path"),
                ("codemode", "Code mode", "Run TypeScript against available tools.", "code"),
            ]
            return .object(["key": .string(key), "source": .string("catalog.tools"), "dependsOn": .array([]), "options": .array(definitions.map { name, label, description, field in
                .object(["value": .string(name), "label": .string(label), "detail": .string(description), "resource": .object([
                    "name": .string(name), "label": .string(label), "description": .string(description),
                    "distribution": .string(name == "read" ? "sdk" : "external"), "source": .string(name == "read" ? "builtin" : "npm:fixture"),
                    "parameters": .object(["type": .string("object"), "properties": .object([field: .object(["type": .string("string"), "description": .string("Fixture \(field) input")])]), "required": .array([.string(field)])]),
                ])])
            } + activeTools.filter { name in !definitions.contains { $0.0 == name } }.map { name in
                // The Gateway lists a chosen tool its catalog no longer offers, so it can be cleared.
                .object(["value": .string(name), "label": .string(name), "disabledReason": .string("Not available here")])
            })])
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
            case "tools.active":
                activeTools = value?.arrayValue?.compactMap(\.stringValue) ?? activeTools
                toolWrite = "\(change["layer"]?.stringValue ?? "?")@\(params["target"]?.objectValue?["kind"]?.stringValue ?? "?")=\(activeTools.joined(separator: ","))"
            case "lab.focusMode": focusMode = value?.stringValue ?? focusMode
            case "lab.paths": paths = value?.arrayValue?.compactMap(\.stringValue) ?? []
            case "lab.weights": weights = value?.objectValue ?? [:]
            case "lab.password": hasSecret = value?.stringValue?.isEmpty == false
            default: break
            }
            applied += 1
        }
        var outcome: [String: JSONValue] = ["changeId": .string(dryRun ? "" : "change-\(applied)"), "key": .string(key),
            "layer": .string("mac"), "status": .string("applied"), "tier": .string("quiet")]
        if dryRun && key == "context.images.block" && ProcessInfo.processInfo.arguments.contains("-settings-renderer-confirm") {
            outcome["confirm"] = .string("Confirm changing image delivery.")
        }
        return .object([
            "status": .string("applied"), "tier": .string("quiet"), "changes": .array([.object(outcome)]),
        ].merging(dryRun ? ["dryRun": .bool(true)] : [:]) { $1 })
    }

    private func key(_ id: String, group: String, subgroup: String? = nil, value: JSONValue?, display: String, layer: String = "builtin",
                     badges: [JSONValue] = [], presentation: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "display": .string(display), "layer": .string(layer), "applied": .bool(true),
            "layers": .array([.object(["layer": .string("mac")].merging(
                ProcessInfo.processInfo.arguments.contains("-settings-ui-tools-write") && id == "tools.active"
                    ? ["value": value ?? .null] : [:]) { $1 })]),
            "badges": .array([.object(["kind": .string("layer"), "label": .string(layer == "mac" ? "Set on Mac" : "Tron default")])] + badges),
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

    private func section(_ id: String, _ title: String, _ order: Int, _ description: String) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "description": .string(description), "order": .number(Double(order))])
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

/// Global Extensions over the Gateway's real package shape: configured Mac
/// packages plus the bundled managed provider `packages.list` appends, and the
/// schema's Sources keys (labels/help mirror the Gateway declarations).
enum HostedExtensionsReview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-settings-ui-extensions") }

    static let configured = ["npm:pi-web-access", "git:github.com/example/pi-agent-browser", "npm:@example/pi-goal",
                             "npm:@example/anthropic-auth", "npm:@example/anthropic-auth-tools"]
    static let bundled = "tron:pi-subagents@0.76.1-tron.9#sha512-fixture"

    static var inventory: JSONValue {
        .object(["packages": .array((configured + [bundled]).map { source in
            .object(["source": .string(source), "scope": .string("user"), "filtered": .bool(false)])
        }), "resources": .object([:])])
    }

    struct SourceKey { let id, label, help, display, importance, control: String; let subgroup: String?; let order: Int; let value: JSONValue }
    static var sourceKeys: [SourceKey] {
        ["extensions", "skills", "prompts", "themes"].enumerated().map { index, name in
            SourceKey(id: "sources.\(name)", label: name.capitalized, help: "Paths searched for \(name).", display: "Not set",
                      importance: "advanced", control: "list", subgroup: "Search paths", order: 10 + index * 10, value: .array([]))
        } + [
            SourceKey(id: "sources.packages", label: "Packages", help: "Installed pi packages.", display: "\(configured.count) packages",
                      importance: "essential", control: "readOnly", subgroup: nil, order: 50,
                      value: .array(configured.map(JSONValue.string))),
            SourceKey(id: "sources.npmCommand", label: "npm command", help: "The command used to install packages.", display: "Not set",
                      importance: "advanced", control: "list", subgroup: nil, order: 60, value: .array([])),
        ]
    }
}

/// Shared synthetic values for visual review of the production settings renderer.
/// Editors still consume the typed values; labels/counts mirror Gateway declarations.
enum HostedSettingsReviewSchema {
    static let sections: [JSONValue] = [
        section("model", "Model", 10, inline: true),
        section("workers", "Workers & delegation", 15, inline: true),
        section("context", "Compaction", 20), section("tools", "Tools", 30),
        section("run", "Connection", 50), section("advanced", "Advanced", 55),
    ]

    private static func section(_ id: String, _ title: String, _ order: Int, inline: Bool = false) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "order": .number(Double(order)), "chatInline": .bool(inline)])
    }

    static func key(_ id: String, _ group: String, _ label: String, _ value: JSONValue,
                    _ display: String, _ control: String = "number", order: Double = 10,
                    help: String = "", subgroup: String? = nil, essential: Bool = false,
                    layer: String = "mac", options: [JSONValue] = []) -> JSONValue {
        let layers = id.hasPrefix("model.queue") ? ["profile", "mac"]
            : ["model.ref[role=chat]", "model.thinking[role=chat]", "tools.active"].contains(id) ? ["chat", "profile", "project", "mac"]
            : id == "permissions.budget.task" ? ["profile"]
            : id.hasPrefix("tools.codemode") || id.hasPrefix("tools.shell") || id == "model.offered" || id == "model.thinkingBudgets" ? ["project", "mac"]
            : id == "permissions.defaultProjectTrust" || id == "run.httpProxy" || id == "run.cacheWarming" ? ["mac"]
            : ["chat", "project", "mac"]
        var row: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "value": value, "display": .string(display),
            "layer": .string(layer), "applied": .bool(true), "origin": .string(layer == "chat" ? "override" : "inherited"),
            "layers": .array(layers.map { .object(["layer": .string($0), "value": $0 == layer ? value : .null]) }),
            "badges": .array([.object(["kind": .string("layer"), "label": .string(layer == "chat" ? "Session" : layer == "profile" ? "Home profile" : "Mac")])]),
            "presentation": .object(["label": .string(label), "help": .string(help.isEmpty && id == "tools.active" ? "The tools the model may call." : help),
                "order": .number(order), "importance": .string(essential ? "essential" : "advanced"),
                "editableLayers": .array(layers.map(JSONValue.string)), "timing": .string("fixed"), "effect": .string("next-turn"),
                "control": .string(control), "valueKind": .string(control == "list" ? "stringList" : control == "number" ? "integer" : "choice"),
                "range": .object(["min": .number(0), "max": .number(1_000_000), "step": .number(1), "unit": .string("tokens")]),
                "options": .array(options)]),
        ]
        if id == "tools.active", var presentation = row["presentation"]?.objectValue {
            presentation["optionsSource"] = .object(["name": .string("catalog.tools"), "dependsOn": .array([])])
            row["presentation"] = .object(presentation)
        }
        if let subgroup { row["subgroup"] = .string(subgroup) }
        return .object(row)
    }

    static let tools = ["ask_user", "display", "notify", "read", "bash", "edit", "write", "web_search", "fetch_content", "knowledge", "computer", "schedule", "connections", "settings", "zoom"]
    static let additionalKeys: [JSONValue] = [
        key("model.thinking[role=chat]", "model", "Thinking", .string("high"), "High", "choice", order: 20,
            help: "How much the model reasons before it answers.", essential: true, layer: "chat",
            options: [.object(["value": .string("high"), "label": .string("High")])]),
        key("model.queue[role=worker]", "workers", "Worker models", .array([.string("anthropic/claude-opus-5-5"), .string("openai/gpt-6")]), "2 models", "list", order: 40, essential: true, layer: "profile"),
        key("model.queue[role=subagent]", "workers", "Subagent models", .array([.string("openai/gpt-6-luna")]), "1 model", "list", order: 42, essential: true, layer: "profile"),
        key("permissions.budget.task", "workers", "Task budget", .object(["inputTokens": .number(200_000)]), "input 200000", "readOnly", order: 50, help: "Tokens one Home task may use, cached included. Empty is no limit.", essential: true, layer: "profile"),
        key("context.compaction.enabled", "context", "Automatic compaction", .bool(true), "On", "toggle", help: "Summarize older conversation when the context fills.", essential: true),
        key("context.compaction.reserveTokens", "context", "Reserve", .number(16_384), "16,384 tokens", order: 20, help: "Tokens kept free for the response before compaction starts."),
        key("context.compaction.keepRecentTokens", "context", "Keep recent", .number(20_000), "20K tokens", order: 30, help: "Recent tokens kept verbatim after compaction."),
        key("context.compaction.instructions", "context", "Summary instructions", .string(""), "—", "text", order: 40, help: "Extra instructions for compaction summaries."),
        key("context.branchSummary.reserveTokens", "context", "Branch summary reserve", .number(16_384), "16,384 tokens", order: 50, help: "Tokens reserved when summarizing an abandoned branch."),
        key("model.thinking[role=summarizer]", "context", "Summary thinking", .string("inherit"), "Same as chat", "choice", order: 80, help: "Thinking level for compaction summaries.", options: [.object(["value": .string("inherit"), "label": .string("Same as chat")])]),
        key("tools.active", "tools", "Tools", .array(tools.map(JSONValue.string)), "15 tools", "checklist", essential: true, layer: "chat"),
        key("tools.codemode.mode", "tools", "Code mode", .string("on"), "On", "choice", order: 20, help: "Let the model call tools from a script.", options: [.object(["value": .string("on"), "label": .string("On")])]),
        key("tools.codemode.inlineBudget", "tools", "Inline budget", .number(16_000), "16000", order: 30, help: "Bytes of script output returned inline."),
        key("tools.shell.path", "tools", "Shell", .string("/bin/bash"), "/bin/bash", "text", order: 40, help: "The shell the bash tool runs."),
        key("tools.shell.commandPrefix", "tools", "Command prefix", .string(""), "—", "text", order: 50, help: "Text run before every shell command."),
        key("context.images.autoResize", "tools", "Resize images", .bool(true), "On", "toggle", order: 60, help: "Shrink large images before they are sent.", subgroup: "Images"),
        key("context.images.block", "tools", "Block images", .bool(false), "Allowed", "toggle", order: 70, help: "Replace images with a placeholder for the model.", subgroup: "Images", layer: "chat"),
        key("run.transport", "run", "Transport", .string("auto"), "Automatic", "choice", order: 90, help: "How requests reach the provider.", essential: true, options: [.object(["value": .string("auto"), "label": .string("Automatic")])]),
        key("run.httpIdleTimeoutMs", "run", "Idle timeout", .number(300_000), "300 s", order: 100, help: "How long a silent HTTP stream may idle."),
        key("run.websocketConnectTimeoutMs", "run", "WebSocket connect timeout", .number(10_000), "10 s", order: 110, help: "How long a WebSocket connection may take to open."),
        key("run.httpProxy", "run", "HTTP proxy", .null, "Not set", "secret", order: 120, help: "Proxy for model requests. Applies after a restart."),
        key("run.cacheWarming", "run", "Cache warming", .string("off"), "Off", "choice", order: 130, help: "Keep model prompt caches warm.", options: [.object(["value": .string("off"), "label": .string("Off")])]),
        key("permissions.defaultProjectTrust", "advanced", "Default trust policy", .string("ask"), "Ask", "choice", order: 20, help: "What happens with a project that has no trust decision.", options: [.object(["value": .string("ask"), "label": .string("Ask")])]),
        key("model.thinkingBudgets", "advanced", "Thinking budgets", .object(["high": .number(16_384)]), "1 budget", "readOnly", order: 60, help: "Token budget per thinking level, for models that take one."),
        key("model.offered", "advanced", "Offered models", .array([]), "0 items", "list", order: 70, help: "Models offered in the picker. Empty offers every model."),
        key("run.queue.steeringMode", "advanced", "Steering delivery", .string("one-at-a-time"), "One at a time", "choice", order: 10, subgroup: "Queue"),
        key("run.queue.followUpMode", "advanced", "Follow-up delivery", .string("one-at-a-time"), "One at a time", "choice", order: 20, subgroup: "Queue"),
        key("run.retry.enabled", "advanced", "Retry", .bool(true), "On", "toggle", order: 30, subgroup: "Retry"),
        key("run.retry.maxRetries", "advanced", "Retries", .number(3), "3 retries", order: 40, subgroup: "Retry"),
    ]
}

#endif

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
    /// `-sheet-haptics-restored`: the cover is already presented when its presenter mounts.
    @State private var covering = ProcessInfo.processInfo.arguments.contains("-sheet-haptics-restored")
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
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-project-lifecycle-preview"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                        HostedProjectLifecyclePreview(surface: ProcessInfo.processInfo.arguments[index + 1])
                    } else if ProcessInfo.processInfo.arguments.contains("-theme-icon-boundary") {
                        HostedThemeIconFixture()
                    } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-six-ui-surface"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                        let surface = ProcessInfo.processInfo.arguments[index + 1]
                        if surface.hasPrefix("worker-") {
                            HostedWorkerToolFixture(surface: surface)
                        } else {
                            HostedSixSmallUIFixture(surface: surface)
                        }
                    } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-settings-three-layer-preview"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                        HostedSettingsThreeLayerPreview(surface: ProcessInfo.processInfo.arguments[index + 1])
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-controls-review") {
                        controlsReview
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-alignment-review") {
                        SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "global", presentation: .section("context"))
                    } else if HostedExtensionsReview.project {
                        SettingsRendererView(target: SettingsTarget.project(cwd: "/fixture/project").gatewayTarget, writeLayer: nil, presentation: .section("tools"))
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-ui-providers") {
                        providerReview
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-ui-push") {
                        PushNotificationsSettingsView()
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-inline-approval-boundary") {
                        HostedInlineApprovalBoundaryFixture()
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-changes") {
                        SettingsChangesView(scope: ProcessInfo.processInfo.arguments.contains("-settings-changes-session")
                            ? .session("fixture-chat", projectCWD: "/fixture/project") : .all,
                            onOpenSession: { openedRoute = $0 })
                    } else if ProcessInfo.processInfo.arguments.contains("-settings-renderer-held-preview") || ProcessInfo.processInfo.arguments.contains("-settings-renderer-confirm") || ProcessInfo.processInfo.arguments.contains("-settings-renderer-haptics") {
                        // The Context sheet itself, so the fixture's cover control stays reachable.
                        SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "global", presentation: .section("context"))
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
                        && !ProcessInfo.processInfo.arguments.contains("-settings-controls-review")
                        && !ProcessInfo.processInfo.arguments.contains("-settings-three-layer-preview")
                        && !ProcessInfo.processInfo.arguments.contains("-six-ui-surface")
                        && !ProcessInfo.processInfo.arguments.contains("-project-lifecycle-preview") {
                    HStack {
                        Text("applied:\(applied)").accessibilityIdentifier("fixture.settings-renderer-applied")
                        Text("held:\(heldPreviews)").accessibilityIdentifier("fixture.settings-renderer-held")
                        if ProcessInfo.processInfo.arguments.contains("-settings-renderer-held-preview") { Button("Cover renderer") { covering = true } }
                        Text("haptics:\(TronHapticsProbe.shared.summary)").accessibilityIdentifier("fixture.haptics")
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
    private var heldPreview: CheckedContinuation<Void, Never>?
    private var previewsHeld = 0
    func previewCount() -> Int { previewsHeld }
    func releasePreview() { heldPreview?.resume(); heldPreview = nil }

    private var hello = true
    private var projectReads = 0
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    // The fixture's stores: one Mac layer over built-ins.
    private var model = "pro"
    private var activeTools = HostedExtensionsReview.builtinOff ? ["read", "+codemode"] : ["read", "retired"]
    private var extensions = HostedExtensionsReview.builtinOff ? ["-builtin:codemode"] : [String]()
    private var toolWrite = "none"
    func lastToolWrite() -> String { toolWrite }
    private var thinking = "high"
    private var invalidValue = ""
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
        case "gateway.update.config.status":
            result = .object(["schema": .number(1), "kind": .string("tron-gateway-update-config"), "sourceRoot": .string("/fixture/projects"), "updatedAt": .string("2026-10-20T00:00:00Z")])
        case "gateway.update.status":
            result = .object(["state": .string("idle"), "channel": .string("stable"), "candidateAvailable": .bool(false), "rollbackAvailable": .bool(false)])
        case "filesystem.list":
            result = .object(["path": params["path"] ?? .string("/fixture/projects"), "parent": .string("/fixture"), "entries": .array([
                .object(["name": .string("Example"), "path": .string("/fixture/projects/Example"), "kind": .string("directory"), "hidden": .bool(false)])
            ])])
        case "session.workspace.inspect" where ProcessInfo.processInfo.arguments.contains("-six-ui-surface"):
            result = .object(["root": .string("/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"), "revision": .string("preview"),
                "repository": .object(["root": .string("/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"),
                    "branch": .null, "head": .string("b8d31a1d12345678"), "detached": .bool(true), "unborn": .bool(false),
                    "dirty": .bool(false), "changes": .array([])])])
        case "session.workspace.list":
            result = .object(["root": .string("/Users/fixture/Workspace/tron-worktrees/six-small-ui-fixes"),
                "path": .string(""), "parent": .null, "revision": .string("preview"), "entries": .array([])])
        case "projects.list":
            projectReads += 1
            if ProcessInfo.processInfo.arguments.contains("-projects-withhold-once"), projectReads == 1 { return }
            if ProcessInfo.processInfo.arguments.contains("-projects-fail-once"), projectReads == 1 {
                try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(false),
                    "error": .object(["code": .string("busy"), "message": .string("Project listing is unavailable. Try again."), "retryable": .bool(true)])]))
                return
            }
            result = .object(["workspace": .string("/fixture/projects"), "projects": .array([
                .object(["name": .string("Example"), "path": .string("/fixture/projects/Example"),
                    "trust": .object(["effectiveDecision": .bool(true)]),
                    "eligibility": .object(Dictionary(uniqueKeysWithValues: ["trust", "github", "rename", "archive", "untrust"].map {
                        ($0, JSONValue.object(["allowed": .bool(true)]))
                    }))])
            ]), "nextCursor": .null])
        case "trust.inspect": result = .object(["requiresDecision": .bool(false), "effectiveDecision": .bool(true)])
        case "git.inspect": result = .object(["isRepository": .bool(true), "branch": .null, "dirty": .bool(false), "branches": .array([]), "commits": .array([])])
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
            if ProcessInfo.processInfo.arguments.contains("-project-lifecycle-preview") {
                throw GatewayFailure(code: "invalid_request", message: "Design previews cannot record a decision.", retryable: false, details: nil)
            }
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
        default: result = HostedExtensionsReview.response(method) ?? HostedSettingsChangesReview.response(method) ?? .object([:])
        }
        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    private var modelName: String { model == "pro" ? "Fixture Pro" : "Fixture Lite" }

    /// #2050 preview requests as `settings.approvals` serves them: a profile
    /// organization action (readable rows, exact identity) and a settings change.
    static let profilePreview: JSONValue = .object(["title": .string("Review exact profile changes"), "items": .array([
        placement("Prefers short morning check-ins over long evening calls.", "Unsorted › Review → Routines & wellbeing › Check ins", "note-1"),
        placement("Keeps a paper notebook for travel plans.", "Unsorted › Review → Life & people › Travel", "note-2"),
        placement("Uses the standing desk after lunch.", "Unsorted › Needs split → Routines & wellbeing", "note-3",
                  detail: "Only placement and revision identity change. Text, confirmation, provenance, authority, status and historical revisions remain exact."),
    ])])

    private static func placement(_ label: String, _ value: String, _ id: String, detail: String? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["label": .string(label), "value": .string(value),
            "exact": .string(#"{"id":"\#(id)-6f1c","revision":"rev-\#(id)-91ab","before":{"version":2,"path":["inferred","review"]},"after":{"version":2,"path":["routines","check-ins"]}}"#)]
        if let detail { item["detail"] = .string(detail) }
        return .object(item)
    }

    private func previewRequests() -> [JSONValue] {
        let now = ISO8601DateFormatter().string(from: Date())
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(23 * 3600))
        let home: JSONValue = .object(["kind": .string("home"), "sessionId": .string("fixture-home")])
        let profile: JSONValue = .object(["requestId": .string("profile-wait"), "digest": .string("digest-profile-wait"),
            "createdAt": .string(now), "expiresAt": .string(expires), "actor": home, "target": .object(["kind": .string("home")]),
            "requester": .string("Home"), "reason": .string("You asked me to sort the Unsorted notes. Placement only: text and history stay unchanged, and the move can be undone."),
            "changes": .array([]),
            "action": .object(["subject": .string("home.profile.review"), "title": Self.profilePreview.objectValue!["title"]!, "items": Self.profilePreview.objectValue!["items"]!])])
        let retries: JSONValue = .object(["requestId": .string("settings-pending"), "digest": .string("digest-settings-pending"),
            "createdAt": .string(now), "expiresAt": .string(expires), "actor": home,
            "target": .object(["kind": .string("session"), "sessionId": .string("fixture-chat")]), "requester": .string("Home"),
            "reason": .string("A flaky provider keeps failing this chat's long runs."),
            "changes": .array([.object(["changeId": .string("pending-settings-pending"), "key": .string("run.retry.maxRetries"),
                "label": .string("Retries"), "layer": .string("session"), "op": .string("set"), "tier": .string("approve"),
                "before": .number(3), "after": .number(5), "display": .object(["before": .string("3 retries"), "after": .string("5 retries")])])])])
        return [profile, retries].filter { decided[$0.objectValue!["requestId"]!.stringValue!] == nil }
    }

    private func previewHistory() -> JSONValue {
        let now = ISO8601DateFormatter().string(from: Date())
        // The Gateway lists a request's pending fact only until a later fact settles it.
        let waiting: [JSONValue] = ["profile-wait", "settings-pending"].filter { decided[$0] == nil }.map { id in
            .object(["changeId": .string(id == "profile-wait" ? id : "pending-\(id)"), "requestId": .string(id), "action": .bool(id == "profile-wait"),
                "at": .string(now), "actor": .object(["kind": .string("home"), "sessionId": .string("fixture-home")]),
                "target": .object(["kind": .string(id == "profile-wait" ? "home" : "session")]), "layer": .string(id == "profile-wait" ? "global" : "session"),
                "key": .string(id == "profile-wait" ? "home.profile.review" : "run.retry.maxRetries"), "op": .string("set"), "tier": .string("approve"),
                "status": .string("pending"), "presentation": .object(["label": .string(id == "profile-wait" ? "Review exact profile changes" : "Retries"),
                    "actor": .string("Home"), "layer": .string(id == "profile-wait" ? "Global" : "Session"),
                    "display": .object(["before": .string(id == "profile-wait" ? "Requested" : "3 retries"), "after": .string(id == "profile-wait" ? "Waiting" : "5 retries")])])])
        }
        let entries: [JSONValue] = waiting + decided.keys.sorted().map { id in
            let status = decided[id] == true ? "approved" : "declined"
            if id == "profile-wait" {
                return .object(["changeId": .string("settled-\(id)"), "requestId": .string(id), "refersTo": .string(id), "action": .bool(true),
                    "at": .string(now), "actor": .object(["kind": .string("home"), "sessionId": .string("fixture-home")]),
                    "target": .object(["kind": .string("home")]), "layer": .string("global"), "key": .string("home.profile.review"),
                    "op": .string("set"), "tier": .string("approve"), "status": .string(status), "after": Self.profilePreview,
                    "reason": .string("You asked me to sort the Unsorted notes. Placement only: text and history stay unchanged, and the move can be undone."),
                    "presentation": .object(["label": .string("Review exact profile changes"), "actor": .string("Home"), "layer": .string("Global"),
                        "display": .object(["before": .string("Requested"), "after": .string(status == "approved" ? "Done" : "Declined")])])])
            }
            return .object(["changeId": .string("settled-\(id)"), "requestId": .string(id), "refersTo": .string("pending-\(id)"),
                "at": .string(now), "actor": .object(["kind": .string("home"), "sessionId": .string("fixture-home")]),
                "target": .object(["kind": .string("session"), "sessionId": .string("fixture-chat")]), "layer": .string("session"),
                "key": .string("run.retry.maxRetries"), "op": .string("set"), "tier": .string("approve"), "status": .string(status),
                "before": .number(3), "after": .number(5), "reason": .string("A flaky provider keeps failing this chat's long runs."),
                "presentation": .object(["label": .string("Retries"), "actor": .string("Home"), "layer": .string("Session"),
                    "display": .object(["before": .string("3 retries"), "after": .string("5 retries")])])])
        }
        return .object(["entries": .array(entries), "nextCursor": .null])
    }

    private func approvalRequests() -> [JSONValue] {
        if ProcessInfo.processInfo.arguments.contains("-project-lifecycle-preview") {
            return HostedProjectApprovalPreview.requests
        }
        if HostedInlineApprovalBoundaryFixture.requestsPreview { return previewRequests() }
        guard ProcessInfo.processInfo.arguments.contains("-settings-changes-approvals") else { return [] }
        return ["approve", "decline"].filter { decided[$0] == nil }.map { id in
            .object(["requestId": .string(id), "digest": .string("digest-\(id)"),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                "expiresAt": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))),
                "actor": .object(["kind": .string("agent"), "sessionId": .string("fixture-chat")]),
                "target": .object(["kind": .string("global")]), "requester": .string("Fixture agent"),
                "changes": .array([.object(["changeId": .string("pending-\(id)"), "key": .string("run.retry.maxRetries"),
                    "label": .string("Request \(id)"), "layer": .string("global"), "op": .string("set"), "tier": .string("approve"),
                    "before": .number(4), "after": .number(6), "display": .object(["before": .string("4 retries"), "after": .string("6 retries")])])])])
        }
    }

    private func historyPage(_ params: [String: JSONValue]) -> JSONValue {
        if HostedInlineApprovalBoundaryFixture.requestsPreview { return previewHistory() }
        if ProcessInfo.processInfo.arguments.contains("-settings-inline-approval-boundary") {
            return .object(["entries": .array(decided.keys.sorted().map { id in
                .object(["changeId": .string("settled-\(id)"), "requestId": .string(id), "refersTo": .string("pending-\(id)"),
                    "at": .string(ISO8601DateFormatter().string(from: Date())), "actor": .object(["kind": .string("agent")]),
                    "target": .object(["kind": .string("global")]), "layer": .string("global"), "key": .string("run.retry.maxRetries"),
                    "op": .string("set"), "tier": .string("approve"), "status": .string(decided[id] == true ? "approved" : "declined"),
                    "before": .number(4), "after": .number(6), "presentation": .object([
                        "label": .string("Request \(id)"), "actor": .string("Fixture agent"), "layer": .string("Global"),
                        "display": .object(["before": .string("4 retries"), "after": .string("6 retries")])])])
            }), "nextCursor": .null])
        }
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
                    "layer": .string("session"),
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
                "target": .object(["kind": .string("global")]), "layer": .string("global"),
                "key": .string("run.retry.maxRetries"), "op": .string("set"), "changed": .bool(true), "redacted": .bool(true),
                "tier": .string("quiet"), "status": .string("applied"),
                "presentation": .object(["label": .string("Agent retry count"), "section": .string("run"),
                    "actor": .string("Agent"), "layer": .string("Global"),
                    "display": .object(["before": .string("Hidden"), "after": .string("Changed")])]),
            ])
        }
        return .object([
            "changeId": .string("fixture-change"), "at": .string("2026-10-11T12:00:00.000Z"),
            "actor": .object(["kind": .string("agent"), "sessionId": .string("fixture-chat")]),
            "target": .object(["kind": .string("global")]), "layer": .string("global"),
            "key": .string("run.retry.maxRetries"), "op": .string("set"),
            "before": .number(4), "after": .number(6), "tier": .string("quiet"), "status": .string("applied"),
            "tierBasis": .object(["direction": .string("widen"), "floor": .string("quiet"), "floorSource": .string("code"),
                "web": .bool(false), "risk": .string("quiet"),
                "riskEvaluation": .object(["status": .string("assessed"), "rationale": .string("The deterministic floor is sufficient.")])]),
            "presentation": .object(["label": .string("Agent retry count"), "section": .string("run"),
                "actor": .string("Agent"), "layer": .string("Global"),
                "display": .object(["before": .string("4 retries"), "after": .string("6 retries")])]),
        ])
    }

    private func resolution() -> JSONValue {
        if ProcessInfo.processInfo.arguments.contains("-settings-expanded-review") {
            let rows = [HostedSettingsReviewSchema.key("model.ref[role=chat]", "model", "Model", .object(["provider": .string("fixture"), "id": .string("pro")]), "Fixture Model", "catalog", essential: true)]
                + (ProcessInfo.processInfo.arguments.contains("-agent-behavior-regression")
                    ? HostedSettingsReviewSchema.agentBehaviorKeys : HostedSettingsReviewSchema.additionalKeys)
                + (ProcessInfo.processInfo.arguments.contains("-settings-sheet-theme-review") ? HostedSettingsReviewSchema.sheetThemeKeys : [])
                + [HostedSettingsReviewSchema.key("setup.sessionDir", "setup", "Session folder", .string("/workspace/sessions"), "/workspace/sessions", "readOnly", help: "Where chats are stored. Applies after a restart."),
                   HostedSettingsReviewSchema.key("setup.installTelemetry", "setup", "Install telemetry", .bool(false), "Off", "toggle", order: 20)]
            if ProcessInfo.processInfo.arguments.contains("-six-ui-surface") {
                return .object(["keys": .array(rows), "sections": .array(HostedSettingsReviewSchema.sections)])
            }
            let keys = rows.compactMap { value -> JSONValue? in
                guard var row = value.objectValue,
                      row["layers"]?.arrayValue?.contains(where: { $0.objectValue?["layer"]?.stringValue == "global" }) == true else { return nil }
                row["layer"] = .string("global")
                row["layers"] = .array([.object(["layer": .string("global"), "value": row["value"] ?? .null])])
                if var presentation = row["presentation"]?.objectValue {
                    presentation["sessionOverridable"] = .bool(false)
                    presentation["projectSettable"] = .bool(false)
                    presentation["editable"] = .bool(true)
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
            // Geometry is the generic renderer's contract, not an editing route
            // for retired compaction keys. Serve the same short/long value shapes
            // as the primitive gallery through schema-negotiated choice controls.
            let keys = [("inherited", "Inherited value", "16,384 tokens", false),
                        ("short", "Short value", "—", false),
                        ("revert", "Owned value", "High", true),
                        ("unset", "Optional override", "16,384 tokens", true)].enumerated().map { index, item -> JSONValue in
                var row = HostedSettingsReviewSchema.key("alignment.\(item.0)", "context", item.1,
                    .string(item.2), item.2, "choice", order: Double(index),
                    options: [.object(["value": .string(item.2), "label": .string(item.2)])]).objectValue!
                row["overridden"] = .bool(item.3)
                return .object(row)
            }
            return .object(["target": .object(["kind": .string("global")]), "layers": .array([.string("global")]),
                "renderer": .object(["version": .number(1)]), "keys": .array(keys),
                "sections": .array(HostedSettingsReviewSchema.sections), "diagnostics": .array([])])
        }
        let keys: [JSONValue] = [
            // A catalog source the app has no dedicated picker for, so the generic
            // paged catalog renders it (real model keys use the shared model picker).
            key("model.ref", group: "model", value: .object(["provider": .string("fixture"), "id": .string(model)]), display: modelName,
                set: true, presentation: presentation("Model", "The model new chats start with.", 10, "essential", "catalog",
                    extra: ["optionsSource": .object(["name": .string("fixture.catalog"), "dependsOn": .array([])])])),
            key("model.thinking", group: "model", value: model == "pro" ? .string(thinking) : .string("off"),
                display: model == "pro" ? thinking.capitalized : "Off", presentation: presentation("Thinking", "How much the model reasons.", 20,
                    "essential", "choice", extra: ["valueKind": .string("orderedChoice"), "optionsSource": .object(["name": .string("catalog.thinkingLevels"),
                                                                              "dependsOn": .array([.string("model.ref")])])])),
            key("context.images.block", group: "context", value: .bool(blockImages), display: blockImages ? "On" : "Off",
                presentation: presentation("Block images", "Images are not sent to the model.", 10, "essential", "toggle")),
            key("tools.active", group: "tools", value: .array(activeTools.map(JSONValue.string)), display: activeTools.joined(separator: ", "),
                layer: HostedExtensionsReview.project ? "project" : "global", set: !HostedExtensionsReview.project, presentation: presentation("Tools", "Tools available to new chats.", 10, "essential", "checklist",
                    extra: ["optionsSource": .object(["name": .string("catalog.tools"), "dependsOn": .array([])])])),
            key("run.retry.maxRetries", group: "run", subgroup: "Retry", value: .number(6), display: "6 retries",
                set: true, presentation: presentation("Retries", "How many times a failed request is retried.", 10, "essential", nil)),
            key("lab.invalidValue", group: "lab", value: .string(invalidValue), display: invalidValue.isEmpty ? "Ready" : invalidValue,
                presentation: presentation("Validation", "A fixture value used to prove Gateway refusal.", 5, "essential", "text")),
            key("run.transport", group: "run", value: .string("sse"), display: "Server-sent events", set: true,
                presentation: presentation("Transport", "How requests reach the provider.", 20, "advanced", nil)),
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
        return .object(["target": .object(["kind": .string("global")]), "layers": .array([.string("global")]),
                        "renderer": .object(["version": .number(1)]), "keys": .array(keys + HostedExtensionsReview.keys(extensions: extensions)), "sections": .array(sections),
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
                toolWrite = "\(change["layer"]?.stringValue ?? "?")@\(params["target"]?.objectValue?["kind"]?.stringValue ?? "?")=\(activeTools.joined(separator: ","))"
            case "sources.extensions": extensions = value?.arrayValue?.compactMap(\.stringValue) ?? []
            case "lab.focusMode": focusMode = value?.stringValue ?? focusMode
            case "lab.paths": paths = value?.arrayValue?.compactMap(\.stringValue) ?? []
            case "lab.weights": weights = value?.objectValue ?? [:]
            case "lab.password": hasSecret = value?.stringValue?.isEmpty == false
            default: break
            }
            applied += 1
        }
        var outcome: [String: JSONValue] = ["changeId": .string(dryRun ? "" : "change-\(applied)"), "key": .string(key),
            "layer": .string("global"), "status": .string("applied"), "tier": .string("quiet")]
        if dryRun && key == "context.images.block" && ProcessInfo.processInfo.arguments.contains("-settings-renderer-confirm") {
            outcome["confirm"] = .string("Confirm changing image delivery.")
        }
        return .object([
            "status": .string("applied"), "tier": .string("quiet"), "changes": .array([.object(outcome)]),
        ].merging(dryRun ? ["dryRun": .bool(true)] : [:]) { $1 })
    }

    /// `set` is a value saved at Global (its Reset is offered); otherwise the row inherits the default.
    private func key(_ id: String, group: String, subgroup: String? = nil, value: JSONValue?, display: String, layer: String = "global",
                     set: Bool = false, badges: [JSONValue] = [], presentation: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "display": .string(display), "layer": .string(layer), "applied": .bool(true),
            "overridden": .bool(set),
            "layers": .array(ProcessInfo.processInfo.arguments.contains("-settings-ui-tools-write") && id == "tools.active"
                ? HostedExtensionsReview.layers(own: value ?? .null) : [.object(["layer": .string("global")])]),
            "badges": .array(badges),
            "presentation": presentation,
        ]
        if let subgroup { object["subgroup"] = .string(subgroup) }
        if let value { object["value"] = value }
        return .object(object)
    }

    private func presentation(_ label: String, _ help: String, _ order: Int, _ importance: String, _ control: String?,
                              extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "label": .string(label), "help": .string(help), "order": .number(Double(order)), "importance": .string(importance),
            "valueKind": .string("fixture"),
            "sessionOverridable": .bool(false), "projectSettable": .bool(false), "editable": .bool(true),
        ]
        if let control { fields["control"] = .string(control) }
        return .object(fields.merging(extra) { $1 })
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
            let capabilities = ProcessInfo.processInfo.arguments.contains("-agent-behavior-regression")
                ? #"["sessions.v1","projects.lifecycle.v1"]"#
                : ProcessInfo.processInfo.arguments.contains("-settings-sheet-theme-review")
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

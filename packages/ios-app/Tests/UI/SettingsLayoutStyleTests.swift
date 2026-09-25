import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class SettingsLayoutStyleTests: XCTestCase {
    func testCustomModelEditorUsesSurroundingSettingsGlass() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let fixture = VStack(spacing: 18) {
                TronSettingsGroup("Connection") {
                    TronValueRow(icon: "cpu", title: "Provider ID", value: "fixture")
                }
                CustomModelIDsEditor(text: .constant("model-small\nmodel-large"))
                TronSettingsGroup("Protocol") {
                    TronValueRow(icon: "network", title: "API Format", value: "OpenAI Chat")
                }
            }
            .padding(20)
            .tronPresentation().tronSettingsLayout().tronSettingsVisualTheme(accent: .tronCyan)
            .background(Color.tronBackground)
            try await withHost(fixture, size: CGSize(width: 440, height: 520), scheme: scheme) { host in
                // Capture the production editor beside its real shared group
                // surfaces so tint/border drift is visible in both appearances.
                attach(image(host), name: "custom-model-editor-shared-glass-\(scheme)")
            }
        }
    }

    func testSettingsRedesignScreensRenderRootAndRepresentativeFixtures() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: cacheRoot))
        defer {
            Task { await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: cacheRoot) }
        }

        try await withHost(
            SettingsView(scope: .dashboard)
                .environment(model)
                .tronPresentation()
                .tronSettingsLayout(),
            size: CGSize(width: 440, height: 900),
            scheme: .dark
        ) { host in
            attach(image(host), name: "settings-redesign-root-dark")
        }
        try await withHost(
            IntegrationsSettingsView(surface: .mcpServers)
                .environment(model)
                .tronPresentation()
                .tronSettingsLayout(),
            size: CGSize(width: 440, height: 900),
            scheme: .dark
        ) { host in
            attach(image(host), name: "settings-redesign-mcp-dark")
        }
        try await withHost(
            PackagesSettingsView(projectCWD: nil)
                .environment(model).tronPresentation().tronSettingsLayout(),
            size: CGSize(width: 440, height: 900), scheme: .light
        ) { host in
            attach(image(host), name: "settings-resource-glass-light")
        }
        try await withHost(
            PackagesSettingsView(projectCWD: "/fixture/project")
                .environment(model)
                .tronPresentation()
                .tronSettingsLayout()
                .environment(\.dynamicTypeSize, .accessibility3),
            size: CGSize(width: 320, height: 900),
            scheme: .light
        ) { host in
            attach(image(host), name: "settings-redesign-resources-accessibility-light")
        }
    }

    func testConnectedServicesRendersOwnerSnapshot() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
        do {
            try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Fixture Mac", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device"), token: "fixture-token")
            for (index, scheme) in [ColorScheme.light, .dark].enumerated() {
                try await withHost(IntegrationsSettingsView(surface: .connectedServices)
                    .environment(model).tronPresentation().tronSettingsLayout(),
                    size: CGSize(width: 440, height: 900), scheme: scheme) { host in
                    let read = try await request(socket, count: index + 2)
                    XCTAssertEqual(read.method, "connections.list")
                    let value = try JSONDecoder.gateway.decode(JSONValue.self, from: Data(#"""
                    {"definitions":[{"schemaVersion":1,"id":"knowledge.raindrop","implementation":"knowledge-connector","displayName":"Raindrop","setupMethods":["token"],"capabilities":[{"id":"read","displayName":"Read bookmarks","effects":["read"],"supported":true}]}],
                    "instances":[{"id":"fixture-account","definitionId":"knowledge.raindrop","implementation":"knowledge-connector","providerAccountId":"101","providerDisplayName":"fixture@example.test","credentialConfigured":true,"credentialAvailability":"available","providerIdentity":"admitted","policy":{"enabled":true,"allowWrites":false,"paidAccessApproved":false,"paidBudgetCents":0,"recurringApproved":false},"health":"ready","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","setupRevision":1}],
                    "capabilities":[{"id":"read","availability":"available","effects":["read"],"definitionId":"knowledge.raindrop","connectionId":"fixture-account","provenance":{"owner":"connection","definitionId":"knowledge.raindrop","connectionId":"fixture-account"}}],"setupOperations":[],"stateRevision":1}
                    """#.utf8))
                    await socket.enqueue(try reply(read.id, value))
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    attach(image(host), name: "connected-services-account-fixture-\(scheme)")
                }
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    func testAgentDefaultsRendersInlineDefaults() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        do {
            for scheme in [ColorScheme.light, .dark] {
                try await withHost(NavigationStack { AgentDefaultsSettingsView(projectCWD: nil) }
                    .environment(model).tronPresentation().tronSettingsLayout().tronSettingsVisualTheme(accent: .tronPurple),
                    size: CGSize(width: 440, height: 900), scheme: scheme) { host in
                    // Interaction is exercised by the HOSTED_TEST UI journey; this
                    // native layout fixture does not expose a complete AX tree.
                    attach(image(host), name: "agent-defaults-inline-defaults-\(scheme)")
                }
                try await withHost(NavigationStack { ProvidersSettingsView(sessionID: nil) }
                    .environment(model).tronPresentation().tronSettingsLayout().tronSettingsVisualTheme(accent: .tronEmerald),
                    size: CGSize(width: 440, height: 900), scheme: scheme) { host in
                    // The catalog row remains first even before provider data arrives.
                    attach(image(host), name: "providers-model-catalog-first-\(scheme)")
                }
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    func testIntegrationMutationSettlementRejoinsAfterPresentationSuspension() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        do {
            for fails in [false, true] {
                let probe = IntegrationMutationProbe()
                let started = expectation(description: "Accepted command started")
                var release: CheckedContinuation<Void, Error>?
                defer { release?.resume(throwing: CancellationError()) }
                var starts = 0
                let accepted = Task<Void, Error> { @MainActor in
                    starts += 1
                    try await withCheckedThrowingContinuation { continuation in
                        release = continuation
                        started.fulfill()
                    }
                }
                probe.pending = IntegrationMutation(identity: model.knowledgePresentationIdentity, task: accepted)
                try await withHost(IntegrationMutationFixture(probe: probe).environment(model), size: CGSize(width: 320, height: 120)) { _ in
                    await fulfillment(of: [started], timeout: 2)
                    probe.active = false
                    try await Task.sleep(for: .milliseconds(40))
                    let continuation = try XCTUnwrap(release)
                    release = nil
                    if fails { continuation.resume(throwing: GatewayFailure(code: "conflict", message: "Fixture conflict", retryable: false, details: nil)) }
                    else { continuation.resume() }
                    _ = await accepted.result
                    try await Task.sleep(for: .milliseconds(40))
                    XCTAssertNotNil(probe.pending, "Inactive observers cannot publish completion")
                    XCTAssertNil(probe.error)
                    XCTAssertEqual(probe.completions, 0)
                    probe.active = true
                    try await Task.sleep(for: .milliseconds(60))
                    XCTAssertNil(probe.pending)
                    XCTAssertEqual(probe.completions, fails ? 0 : 1)
                    XCTAssertEqual(probe.error != nil, fails)
                    XCTAssertEqual(starts, 1, "Resuming presentation must not replay an accepted command")
                }
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    func testFlatSummaryKeepsItsContainerWithoutBackdropGlass() async throws {
        for scheme in [ColorScheme.light, .dark] {
            try await withHost(Text("Summary").font(TronTypography.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(14)
                .modifier(DetailBodySurface(usesGlass: false, accent: .tronEmerald))
                .background(Color.tronBackground), size: CGSize(width: 360, height: 120), scheme: scheme) { host in
                XCTAssertFalse(descendants(host.view).contains { $0 is UIVisualEffectView })
                let bitmap = image(host)
                let inside = try pixel(bitmap, x: 5, y: 60)
                let outside = try pixel(bitmap, x: 0, y: 0)
                XCTAssertGreaterThan(zip(inside, outside).map { abs($0 - $1) }.reduce(0, +), 0.03,
                                     "A flat compaction summary still needs a painted rounded container")
                attach(bitmap, name: "flat-summary-surface-\(scheme)")
            }
        }
    }

    func testEmptyResolvedResourcesRetainGlassPlaceholderRows() async throws {
        try await withHost(PackageResolvedResourcesSection(resources: .object([:]))
            .tronPresentation().background(Color.tronBackground), size: CGSize(width: 404, height: 500)) { host in
            let bitmap = image(host)
            // SwiftUI glass need not expose a UIVisualEffectView. Sample the
            // right edge, away from text/icons: three broad tinted bands prove
            // the actual placeholder containers, unlike the old bare captions.
            var bands = 0
            var paintedRows = 0
            var wasTinted = false
            for y in 0..<500 {
                let rgb = try pixel(bitmap, x: 396, y: CGFloat(y))
                let tinted = (rgb.max() ?? 0) - (rgb.min() ?? 0) > 0.04
                if tinted { paintedRows += 1 }
                if tinted && !wasTinted { bands += 1 }
                wasTinted = tinted
            }
            XCTAssertGreaterThanOrEqual(bands, 3)
            XCTAssertGreaterThanOrEqual(paintedRows, 90)
            attach(bitmap, name: "empty-resource-containers")
        }
    }

    func testFreeTextSettingsUseEmptyPlaceholderWithoutChangingValues() async throws {
        for value in ["", "  ", "prefix"] {
            try await withHost(TronTextSettingRow(icon: "chevron.left.forwardslash.chevron.right",
                title: "Code block indent", value: .constant(value)).tronSettingsLayout(),
                size: CGSize(width: 404, height: 80)) { host in
                let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
                XCTAssertEqual(field.placeholder, "(empty)")
                XCTAssertEqual(field.text, value, "The placeholder must not replace or trim authored text")
            }
        }
    }

    func testSharedPillAndPlainNumericValueUseTheSettingsStandard() async throws {
        let pill = UIHostingController(rootView: TronInlineActionLabel("Extra High").tronSettingsLayout())
        pill.safeAreaRegions = []
        XCTAssertEqual(pill.sizeThatFits(in: CGSize(width: 404, height: 200)).height, 44, accuracy: 1)
        try await withHost(TronNumberSettingRow(icon: "number", title: "Token Budget", value: .constant(20_000))
            .tronSettingsLayout().environment(\.dynamicTypeSize, .large), size: CGSize(width: 404, height: 80)) { host in
            let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
            let font = try XCTUnwrap(field.font)
            // Bundled code fonts need not advertise UIKit's traitMonoSpace.
            // Equal glyph advances protect actual monospace behavior instead.
            let narrow = ("iiiiii" as NSString).size(withAttributes: [.font: font]).width
            let wide = ("WWWWWW" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(narrow, wide, accuracy: 0.5, "Code face: \(font.fontName)")
            XCTAssertEqual(field.textAlignment, .right)
            XCTAssertEqual(font.pointSize, TronTypography.sizeSecondary + 0.5, accuracy: 0.5)
        }
    }

    func testNumericInputCommitsOnlyCompleteTextAndRetiresWithItsScope() async throws {
        let probe = SettingsNumericProbe()
        try await withHost(SettingsNumericFixture(probe: probe), size: CGSize(width: 404, height: 160)) { host in
            let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
            field.becomeFirstResponder()
            field.text = "2"
            field.sendActions(for: .editingChanged)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(probe.writes.isEmpty, "A partial budget must not enter autosave")
            field.text = "20x"
            field.sendActions(for: .editingChanged)
            field.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(probe.writes.isEmpty, "Malformed text must not silently save its numeric prefix")
            field.becomeFirstResponder()
            field.text = "20000"
            field.sendActions(for: .editingChanged)
            try await Task.sleep(for: .milliseconds(30))
            field.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(probe.writes, [20_000])
            field.becomeFirstResponder()
            field.text = "12345"
            field.sendActions(for: .editingChanged)
            try await Task.sleep(for: .milliseconds(30))
            probe.scope.scope += 1
            try await Task.sleep(for: .milliseconds(30))
            field.resignFirstResponder()
            XCTAssertEqual(probe.writes, [20_000], "A same-valued successor scope cannot inherit the old numeric draft")
        }
        XCTAssertNil(TronNumberSettingRow.parse(""))
        XCTAssertNil(TronNumberSettingRow.parse("1.5"))
        XCTAssertNil(TronNumberSettingRow.parse("99999999999999999999999999999"))
    }

    func testEnabledToggleHasActualDarkModeThumbContrast() async throws {
        for scheme in [ColorScheme.light, .dark] {
            try await withHost(TronToggleRow(icon: "arrow.clockwise", title: "Automatic Retry", accent: .tronPurple, isOn: .constant(true))
                .tronSettingsLayout().environment(\.colorScheme, scheme).background(Color.tronSurface),
                size: CGSize(width: 404, height: 64), scheme: scheme) { host in
                let image = image(host)
                let right = CGFloat(404) - TronSettingsLayoutPolicy.rowHorizontalPadding
                let thumb = try pixel(image, x: right - TronToggleMotionPolicy.controlHeight / 2, y: 32)
                let track = try pixel(image, x: right - TronToggleMotionPolicy.controlWidth + 8, y: 32)
                if scheme == .dark {
                    XCTAssertGreaterThan(thumb.min() ?? 0, 0.8, "Enabled thumb must remain light after native glass compositing")
                    XCTAssertGreaterThan(thumb.reduce(0, +) / 3 - track.reduce(0, +) / 3, 0.25)
                } else {
                    XCTAssertGreaterThan(thumb[2], thumb[1], "Light mode retains the purple thumb")
                }
                attach(image, name: "settings-toggle-\(scheme)")
            }
        }
    }

    func testReusableSettingsRowsAndOpaqueTitlesRenderInBothAppearances() async throws {
        for (name, scheme, typeSize, width) in [("light", ColorScheme.light, DynamicTypeSize.large, CGFloat(440)),
                                               ("dark", .dark, .large, 440), ("large-text", .dark, .accessibility3, 320)] {
            let fixture = ScrollView {
                VStack(spacing: 18) {
                    TronSettingsGroup("Model Defaults", accent: .tronPurple) {
                        VStack(spacing: 0) {
                            TronSelectionRow(icon: "cpu", title: "Model", detail: "Default for new sessions", value: "Example Model", accent: .tronPurple) { Button("Example Model") {} }
                            TronSettingsDivider(accent: .tronPurple)
                            TronSelectionRow(icon: "brain", title: "Thinking", detail: "Reasoning effort for new sessions", value: "Extra High", accent: .tronPurple) { Button("Extra High") {} }
                            TronSettingsDivider(accent: .tronPurple)
                            TronSelectionRow(icon: "gauge.with.dots.needle.50percent", title: "Context Window", detail: "Conversation capacity", value: "272,000", accent: .tronPurple) { Button("272,000") {} }
                            TronSettingsDivider(accent: .tronPurple)
                            TronToggleRow(icon: "arrow.clockwise", title: "Automatic Retry", accent: .tronPurple, isOn: .constant(true))
                        }
                    }
                    TronSettingsGroup("Installed", accent: .tronBlue) {
                        TronSettingsRow(icon: "shippingbox.fill", title: "git:example.org/tools/long-unbroken-browser-extension@0123456789abcdef", subtitle: "Global", titleIsIdentifier: true, accent: .tronBlue) {
                            TronInlineActionLabel("", icon: "ellipsis", accent: .tronBlue)
                        }
                    }
                    TronSettingsGroup("Context Budgets", accent: .tronPurple) {
                        TronNumberSettingRow(icon: "number", title: "Reserve Tokens", detail: "Response headroom", value: .constant(16_384), accent: .tronPurple)
                    }
                }.padding(18)
            }
            .tronPresentation().tronSettingsLayout().background(Color.tronBackground)
            .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, typeSize)
            try await withHost(fixture, size: CGSize(width: width, height: 700), scheme: scheme) { host in
                let horizontal = descendants(host.view).compactMap { $0 as? UIScrollView }.filter { $0.contentSize.width > $0.bounds.width + 10 }
                XCTAssertFalse(horizontal.isEmpty, "An opaque source must stay continuous and horizontally inspectable")
                attach(image(host), name: "settings-shared-rows-\(name)")
            }
        }
    }

    func testCompactionRuntimeUsesStandardRowsAndNeutralNotes() async throws {
        let configuration = CompactionConfiguration(enabled: true, reserveTokens: 16_384, keepRecentTokens: 20_000,
            thinkingLevel: "inherit", instructions: "Keep key decisions and open tasks",
            source: Dictionary(uniqueKeysWithValues: ["enabled", "reserveTokens", "keepRecentTokens", "thinkingLevel", "instructions"].map { ($0, "default") }),
            model: ModelRef(provider: "example", id: "example-model"), requestedThinkingLevel: "xhigh",
            effectiveThinkingLevel: "xhigh", reason: nil)
        let policy = CompactionPolicyProjection(next: configuration,
            currentBudgets: .init(enabled: true, reserveTokens: 16_384, keepRecentTokens: 20_000),
            active: nil, extensionMayOverride: true, warning: "Focus applies to the next summary.")
        let fixture = ScrollView {
            CompactionRuntimeSection(policy: policy).padding(18)
        }
        .tronPresentation().tronSettingsLayout().tronSettingsVisualTheme(accent: .tronPurple)
        .background(Color.tronBackground).environment(\.colorScheme, .dark)
        XCTAssertTrue(configuration.isValid)
        try await withHost(fixture, size: CGSize(width: 440, height: 700), scheme: .dark) { host in
            let capture = image(host)
            attach(capture, name: "settings-compaction-runtime-dark")
            XCTAssertEqual(try yellowPixelCount(capture), 0, "Runtime information and warnings must not render yellow")
        }
    }

    func testPassiveCaptionsAndSharedResourceRows() async throws {
        try await withHost(TronSettingsCaption("This explanation is not an action.")
            .background(Color.tronBackground), size: CGSize(width: 404, height: 70), scheme: .dark) { host in
            XCTAssertFalse(descendants(host.view).contains { $0 is UIVisualEffectView }, "A passive caption must not acquire a glass card")
            XCTAssertFalse(descendants(host.view).contains { $0 is UIControl })
        }
        let resources: JSONValue = .object([
            "skills": .array([resource("/skills/tron-code-health/SKILL.md", source: "auto", scope: "project"),
                              resource("/skills/tron-ios/SKILL.md", source: "auto", scope: "project")]),
            "prompts": .array([resource("/prompts/parallel-review.md", source: "npm:example-tools", scope: "user"),
                               resource("/prompts/review-loop.md", source: "npm:example-tools", scope: "user")]),
            "themes": .array([])
        ])
        for scheme in [ColorScheme.light, .dark] {
            let fixture = ScrollView {
                VStack(spacing: 18) {
                    TronSettingsNotice(message: "The Mac gateway is offline.", retry: {})
                    TronSettingsRow(icon: "cpu", title: "Example Provider", subtitle: "2 model IDs · OpenAI Chat") {
                        Button {} label: { TronInlineActionLabel("Configure") }
                    }
                    .tronGlassSurface(accent: .tronPurple)
                    .tronSettingsVisualTheme(accent: .tronPurple)
                    .tronSettingsCaption("Valid changes save automatically. Restart the Gateway manually when ready to activate changes to its model registry.")
                    PackageResolvedResourcesSection(resources: resources)
                }.padding(18)
            }
            .tronPresentation().tronSettingsLayout().background(Color.tronBackground)
            .environment(\.colorScheme, scheme)
            try await withHost(fixture, size: CGSize(width: 440, height: 880), scheme: scheme) { host in
                attach(image(host), name: "settings-captions-resources-\(scheme)")
            }
        }
    }

    func testVisiblePackagesRefreshAfterForegroundWithoutRetry() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
        do {
            try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"), token: "token")
            try await withHost(PackagesSettingsView(projectCWD: nil).environment(model).tronPresentation().tronSettingsLayout(),
                               size: CGSize(width: 440, height: 800)) { _ in
                let failed = try await request(socket, count: 2)
                XCTAssertEqual(failed.method, "packages.list")
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(failed.id), "ok": .bool(false),
                    "error": .object(["code": .string("disconnected"), "message": .string("The Mac gateway is offline."), "retryable": .bool(true)])
                ])))
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertNotNil(model.packageError(for: .global))
                // Exercise the real successful-foreground boundary on a live
                // transport; epoch replacement itself is owned by lifecycle tests.
                let reconciliation = model.becameActive()
                await reconciliation?.value
                // A live foreground re-reads the visible package page; respond to
                // its method even when unrelated model reads interleave.
                let refreshed = try await request(socket, method: "packages.list", startingAt: 2)
                await socket.enqueue(try reply(refreshed.id, .object(["packages": .array([]), "resources": .object([
                    "extensions": .array([]), "skills": .array([]), "prompts": .array([]), "themes": .array([])
                ])])))
                let updates = try await request(socket, method: "packages.checkUpdates", startingAt: 3)
                XCTAssertEqual(updates.method, "packages.checkUpdates")
                await socket.enqueue(try reply(updates.id, .object(["updates": .array([])])))
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertNil(model.packageError(for: .global))
                XCTAssertNotNil(model.packageInventory(for: .global))
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    private func resource(_ path: String, source: String, scope: String) -> JSONValue {
        .object(["path": .string(path), "enabled": .bool(true),
                 "metadata": .object(["source": .string(source), "scope": .string(scope), "origin": .string("package")])])
    }
    func testProviderRowsKeepLightweightIndividualSurfaces() async throws {
        let provider = ProviderSummary(
            id: "openai-codex", name: "OpenAI Codex", configured: true, usageSupported: true, localOnly: nil,
            authSource: "oauth", credentialType: "oauth", authMethods: ["oauth"], modelCount: 2
        )
        try await withHost(
            ProviderSetupRow(provider: provider)
                .environment(\.colorScheme, .dark)
                .tronPresentation().tronSettingsLayout(),
            size: CGSize(width: 440, height: 100)
        ) { host in
            XCTAssertFalse(
                descendants(host.view).contains { $0 is UIVisualEffectView },
                "Individual provider surfaces must not add a per-row glass compositor"
            )
            XCTAssertEqual(host.view.bounds.width, 440, accuracy: 1)
            attach(image(host), name: "provider-rounded-row")
        }
    }

    func testProviderGroupsCoverUsageActionsAndAccessibilitySizing() async throws {
        let configuredWithoutUsage = ProviderSummary(
            id: "configured-without-usage", name: "Configured Provider Without Usage", configured: true, usageSupported: false, localOnly: nil,
            authSource: "api-key", credentialType: "api-key", authMethods: ["api-key"], modelCount: 1
        )
        let available = ProviderSummary(
            id: "available-provider", name: "Available Provider With A Longer Display Name", configured: false, usageSupported: nil, localOnly: nil,
            authSource: nil, credentialType: nil, authMethods: ["api-key"], modelCount: 1
        )
        let usage = ProviderUsageSnapshot(
            providerId: "configured-with-usage", status: .available, source: "provider.usage", scope: .account,
            updatedAt: "2026-01-02T03:04:05.123Z",
            windows: [
                UsageWindow(id: "primary", label: "5h", usedPercent: 24, resetsAt: "2026-01-02T05:00:00Z", windowSeconds: 18_000),
                UsageWindow(id: "weekly", label: "Weekly", usedPercent: 63, resetsAt: "2026-01-08T03:00:00Z", windowSeconds: 604_800)
            ]
        )
        let configuredWithUsage = ProviderSummary(
            id: "configured-with-usage", name: "Configured Provider", configured: true, usageSupported: true, localOnly: nil,
            authSource: "oauth", credentialType: "oauth", authMethods: ["oauth"], modelCount: 1
        )
        for width in [320, 375, 393] {
            try await withHost(
                ProviderSetupRow(provider: configuredWithUsage, usageSnapshot: usage)
                    .padding(16)
                    .tronPresentation().tronSettingsLayout()
                    .tronSettingsVisualTheme(accent: .tronPurple),
                size: CGSize(width: width, height: 140), scheme: .light
            ) { host in
                attach(image(host), name: "provider-usage-light-\(width)")
            }
        }
        for (name, typeSize) in [("grouped-light", DynamicTypeSize.large), ("grouped-accessibility", .accessibility3)] {
            try await withHost(
                VStack(spacing: TronSpacing.section) {
                    TronSettingsGroup("Configured", accent: .tronPurple, surfaceStyle: .glass) {
                        ProviderSetupRow(surfaceStyle: .grouped, provider: configuredWithUsage, usageSnapshot: usage)
                        TronSettingsDivider(accent: .tronPurple)
                        ProviderSetupRow(surfaceStyle: .grouped, provider: configuredWithoutUsage)
                    }
                    TronSettingsGroup("Available", accent: .tronPurple, surfaceStyle: .glass) {
                        ProviderSetupRow(surfaceStyle: .grouped, provider: available)
                        TronSettingsDivider(accent: .tronPurple)
                        ProviderSetupRow(surfaceStyle: .grouped, provider: ProviderSummary(
                            id: "available-second", name: "Another Available Provider", configured: false, usageSupported: nil, localOnly: nil,
                            authSource: nil, credentialType: nil, authMethods: ["api-key"], modelCount: 1
                        ))
                    }
                }
                .padding(16)
                .tronPresentation().tronSettingsLayout()
                .tronSettingsVisualTheme(accent: .tronPurple)
                .environment(\.dynamicTypeSize, typeSize),
                size: CGSize(width: 393, height: name == "grouped-light" ? 700 : 1_500), scheme: name == "grouped-light" ? .light : .dark
            ) { host in
                attach(image(host), name: "provider-rows-\(name)")
            }
        }
    }

    func testProviderUsagePlaceholderReservesTheResolvedUsageLineHeight() async throws {
        let provider = ProviderSummary(
            id: "opencode-go", name: "Opencode Go", configured: true, usageSupported: true, localOnly: nil,
            authSource: "api-key", credentialType: "api-key", authMethods: ["api-key"], modelCount: 3
        )
        let usage = ProviderUsageSnapshot(
            providerId: "opencode-go", status: .available,
            windows: [
                UsageWindow(id: "rolling", label: "5h", usedPercent: 0, windowSeconds: 18_000),
                UsageWindow(id: "weekly", label: "Weekly", usedPercent: 7, windowSeconds: 604_800)
            ]
        )
        // The placeholder must occupy the same slot as the resolved summary, or
        // the row would still jump when the snapshot lands.
        for width in [320, 375, 393] {
            let loading = UIHostingController(
                rootView: ProviderSetupRow(surfaceStyle: .grouped, provider: provider, isUsageLoading: true)
                    .tronPresentation().tronSettingsLayout()
            )
            let resolved = UIHostingController(
                rootView: ProviderSetupRow(surfaceStyle: .grouped, provider: provider, usageSnapshot: usage)
                    .tronPresentation().tronSettingsLayout()
            )
            loading.safeAreaRegions = []
            resolved.safeAreaRegions = []
            let proposal = CGSize(width: CGFloat(width), height: 400)
            XCTAssertEqual(
                loading.sizeThatFits(in: proposal).height,
                resolved.sizeThatFits(in: proposal).height,
                accuracy: 1,
                "The usage placeholder must match the resolved line height at width \(width)"
            )
        }
        try await withHost(
            ProviderSetupRow(surfaceStyle: .grouped, provider: provider, isUsageLoading: true)
                .padding(16)
                .tronPresentation().tronSettingsLayout()
                .tronSettingsVisualTheme(accent: .tronPurple),
            size: CGSize(width: 393, height: 120), scheme: .dark
        ) { host in
            attach(image(host), name: "provider-usage-loading")
        }
        try await withHost(
            ProviderSetupRow(surfaceStyle: .grouped, provider: provider, isUsageLoading: true)
                .padding(16)
                .tronPresentation().tronSettingsLayout()
                .tronSettingsVisualTheme(accent: .tronPurple),
            size: CGSize(width: 393, height: 120), scheme: .light
        ) { host in
            attach(image(host), name: "provider-usage-loading-light")
        }
    }

    func testConfiguredProviderRowAndDetailSheetRenderLightDarkAndLargeText() async throws {
        let provider = ProviderSummary(
            id: "openai-codex", name: "OpenAI Codex", configured: true, usageSupported: true, localOnly: nil,
            authSource: "oauth", credentialType: "oauth", authMethods: ["oauth"], modelCount: 2
        )
        let snapshot = ProviderUsageSnapshot(
            providerId: "openai-codex", status: .available, source: "codex.account", scope: .account,
            updatedAt: "2026-01-02T03:04:05.123Z",
            windows: [
                UsageWindow(id: "primary", label: "5h", usedPercent: 24, resetsAt: "2026-01-02T05:00:00Z", windowSeconds: 18_000),
                UsageWindow(id: "secondary", label: "Weekly", usedPercent: 63, resetsAt: "2026-01-08T03:00:00Z", windowSeconds: 604_800)
            ]
        )
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","provider-usage.v1"]}"#.utf8))
        do {
        try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"), token: "token")
        XCTAssertTrue(model.gatewayInfo?.capabilities.contains(ProviderUsageCapability.name) == true)
        let usageResult = try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(ProviderUsageResponse(providers: [snapshot])))
        for (scheme, name, typeSize) in [(ColorScheme.light, "light", DynamicTypeSize.large), (.dark, "dark", .large), (.dark, "dark-large-text", .accessibility3)] {
            try await withHost(
                ProviderSetupRow(provider: provider, usageSnapshot: snapshot)
                    .environment(model).tronPresentation().tronSettingsLayout()
                    .environment(\.dynamicTypeSize, typeSize),
                size: CGSize(width: 440, height: 150), scheme: scheme
            ) { host in
                attach(image(host), name: "provider-row-\(name)")
            }
            let nextRequest = await socket.sentFrames().count + 1
            try await withHost(
                ProviderConfigurationSheet(provider: provider, target: .global)
                    .environment(model).tronPresentation().tronSettingsLayout()
                    .environment(\.dynamicTypeSize, typeSize),
                size: CGSize(width: 440, height: 700), scheme: scheme
            ) { host in
                let usageRequest = try await request(socket, count: nextRequest)
                XCTAssertEqual(usageRequest.method, "provider.usage")
                await socket.enqueue(try reply(usageRequest.id, usageResult))
                // Allow the accepted synthetic RPC to publish and lay out before capture.
                try await Task.sleep(for: .milliseconds(350))
                host.view.layoutIfNeeded()
                attach(image(host), name: "provider-detail-sheet-\(name)")
            }
        }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    private struct SettingsRequest: Decodable { let id: String; let method: String }
    private func request(_ socket: ScriptedGatewaySocket, method: String, startingAt: Int = 0) async throws -> SettingsRequest {
        var index = startingAt
        while true {
            let frames = await socket.sentFrames()
            for frame in frames.dropFirst(index) {
                if let request = try? JSONDecoder.gateway.decode(SettingsRequest.self, from: frame), request.method == method {
                    return request
                }
            }
            index = frames.count
            do {
                let sentCount = index + 1
                try await withTestWatchdog(timeout: .seconds(3)) { try await socket.waitUntilSent(count: sentCount) }
            } catch {
                let sent = frames.compactMap { try? JSONDecoder.gateway.decode(SettingsRequest.self, from: $0).method }
                XCTFail("Missing settings request for \(method); received \(sent)")
                throw error
            }
        }
    }
    private func request(_ socket: ScriptedGatewaySocket, count: Int) async throws -> SettingsRequest {
        do {
            try await withTestWatchdog(timeout: .seconds(3)) { try await socket.waitUntilSent(count: count) }
        } catch {
            let sent = await socket.sentFrames().compactMap { try? JSONDecoder.gateway.decode(SettingsRequest.self, from: $0).method }
            XCTFail("Missing settings request \(count); received \(sent)")
            throw error
        }
        return try JSONDecoder.gateway.decode(SettingsRequest.self, from: await socket.sentFrames()[count - 1])
    }
    private func reply(_ id: String, _ result: JSONValue) throws -> Data {
        try JSONEncoder.gateway.encode(JSONValue.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    func testBalanceAndLocalProviderUsageRenderRowAndDetailFixtures() async throws {
        let moonshot = ProviderSummary(
            id: "moonshotai", name: "Moonshot AI", configured: true, usageSupported: true, localOnly: false,
            authSource: "stored", credentialType: "api_key", authMethods: ["api_key"], modelCount: 4
        )
        let ollama = ProviderSummary(
            id: "ollama", name: "Ollama", configured: true, usageSupported: false, localOnly: true,
            authSource: "models_json_key", credentialType: nil, authMethods: [], modelCount: 2
        )
        let balance = ProviderUsageSnapshot(
            providerId: "moonshotai", status: .available, source: "moonshotai.balance", scope: .account,
            updatedAt: "2026-01-02T03:04:05Z",
            balances: [
                UsageBalance(id: "available", label: "Available", amount: 49.58894, currency: "USD"),
                UsageBalance(id: "voucher", label: "Voucher", amount: 46.58893, currency: "USD"),
                UsageBalance(id: "cash", label: "Cash", amount: 3.00001, currency: "USD")
            ]
        )
        XCTAssertEqual(ProviderUsagePresentation.summary(balance), "$49.59 Available")
        XCTAssertTrue(ProviderUsagePresentation.showsLocalUnlimited(configured: true, localOnly: true, snapshot: nil, isLoading: false))
        try await withHost(
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                TronSettingsGroup("Configured", accent: .tronPurple, surfaceStyle: .glass) {
                    ProviderSetupRow(surfaceStyle: .grouped, provider: moonshot, usageSnapshot: balance)
                    TronSettingsDivider(accent: .tronPurple)
                    ProviderSetupRow(surfaceStyle: .grouped, provider: ollama)
                }
                TronSettingsGroup("Account Usage", accent: .tronEmerald) {
                    VStack(alignment: .leading, spacing: 10) {
                        ProviderUsageSummaryView(snapshot: balance, detail: true)
                    }
                    .padding(.top, 8).padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
            .padding(16)
            .tronPresentation().tronSettingsLayout()
            .tronSettingsVisualTheme(accent: .tronPurple),
            size: CGSize(width: 393, height: 760), scheme: .dark
        ) { host in
            attach(image(host), name: "provider-balance-and-local-dark")
        }
    }

    func testProviderUsageSummaryAndDetailRenderLightAndDarkFixtures() async throws {
        let snapshot = ProviderUsageSnapshot(
            providerId: "openai-codex", status: .available, source: "account", scope: .account,
            updatedAt: "2026-01-02T03:04:05Z", stale: true,
            windows: [
                UsageWindow(id: "short", label: "5h", usedPercent: 24, used: 24, limit: 100, remaining: 76, unit: "requests", resetsAt: "2026-01-02T05:00:00Z", windowSeconds: 18_000),
                UsageWindow(id: "weekly", label: "Weekly", usedPercent: 63, used: 63, limit: 100, remaining: 37, unit: "requests", windowSeconds: 604_800)
            ],
            balances: [UsageBalance(id: "credit", label: "Credit", amount: 12.5, currency: "USD")]
        )
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            try await withHost(
                VStack(alignment: .leading, spacing: 14) {
                    ProviderUsageSummaryView(snapshot: snapshot)
                    ProviderUsageSummaryView(snapshot: snapshot, detail: true)
                }
                .padding(16)
                .background(Color.tronSurface)
                // Match the provider detail sheet, which inherits the settings
                // layout's secondary text adjustment.
                .tronPresentation().tronSettingsLayout(),
                size: CGSize(width: 404, height: 360), scheme: scheme
            ) { host in
                attach(image(host), name: "provider-usage-\(name)")
            }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func image<Content: View>(_ host: UIHostingController<Content>) -> UIImage {
        UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
    }
    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [Double] {
        let bitmap = try XCTUnwrap(image.cgImage)
        let point = try XCTUnwrap(bitmap.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: 1, height: 1)))
        var values = [UInt8](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(point, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return values.prefix(3).map { Double($0) / 255 }
    }
    private func yellowPixelCount(_ image: UIImage) throws -> Int {
        let bitmap = try XCTUnwrap(image.cgImage)
        let width = 220, height = 350
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 204 && bytes[$0 + 1] > 128 && bytes[$0 + 2] < 89 }.count
    }

    private func withHost<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme = .light, check: (UIHostingController<Content>) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "settings fixture appeared")
        let host = SettingsStyleHost(rootView: content)
        host.onAppear = { appeared.fulfill() }
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        await fulfillment(of: [appeared], timeout: 2)
        host.view.layoutIfNeeded()
        try await check(host)
    }
}

@MainActor @Observable
private final class IntegrationMutationProbe {
    var pending: IntegrationMutation?
    var error: String?
    var active = true
    var completions = 0
}

private struct IntegrationMutationFixture: View {
    @Bindable var probe: IntegrationMutationProbe
    var body: some View {
        Text("Accepted integration command")
            .modifier(IntegrationMutationObserver(mutation: $probe.pending, error: $probe.error) { probe.completions += 1 })
            .environment(\.tronPresentationActivity, probe.active ? .active : .covered)
    }
}

@MainActor @Observable
private final class SettingsNumericProbe {
    var value = 16_384
    var writes: [Int] = []
    var scope = TronSettingsInputScope()
}

private struct SettingsNumericFixture: View {
    let probe: SettingsNumericProbe
    var body: some View {
        TronNumberSettingRow(icon: "number", title: "Budget", value: Binding(
            get: { probe.value }, set: { probe.value = $0; probe.writes.append($0) }
        ))
        .tronSettingsLayout().environment(\.tronSettingsInputScope, probe.scope)
    }
}

@MainActor
private final class SettingsStyleHost<Content: View>: UIHostingController<Content> {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let action = onAppear
        onAppear = nil
        action?()
    }
}

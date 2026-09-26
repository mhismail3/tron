import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class SettingsLayoutStyleTests: XCTestCase {

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

    func testVisiblePackagesRefreshAfterForegroundWithoutRetry() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
        do {
            try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"), token: "token")
            try await withHost(ExtensionsSettingsView(projectCWD: nil).environment(model).tronPresentation().tronSettingsLayout(),
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

    func testExtensionsSheetReadsTronModulesOnlyWhenTheGatewayAdvertisesThem() async throws {
        for capabilities in [["sessions.v1", "modules.v1"], ["sessions.v1"]] {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let model = AppModel(client: client, cache: SnapshotCache(root: root))
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("hello"), "gatewayVersion": .string("1.0.0"), "piVersion": .string("1.0.0"),
                "protocolVersion": .number(5), "minProtocolVersion": .number(5), "machineId": .string("machine"),
                "machineName": .string("Mac"), "gatewayChannel": .string("stable"),
                "capabilities": .array(capabilities.map(JSONValue.string)),
            ])))
            do {
                try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                    machineId: "machine", deviceId: "device"), token: "token")
                try await withHost(ExtensionsSettingsView(projectCWD: nil).environment(model).tronPresentation().tronSettingsLayout(),
                                   size: CGSize(width: 440, height: 800)) { _ in
                    let listing = try await request(socket, method: "packages.list")
                    await socket.enqueue(try reply(listing.id, .object(["packages": .array([]), "resources": .object([
                        "extensions": .array([]), "skills": .array([]), "prompts": .array([]), "themes": .array([])
                    ])])))
                    let updates = try await request(socket, method: "packages.checkUpdates")
                    await socket.enqueue(try reply(updates.id, .object(["updates": .array([])])))
                    if capabilities.contains("modules.v1") {
                        let modules = try await request(socket, method: "modules.list")
                        await socket.enqueue(try reply(modules.id, .object([
                            "modules": .array([.object([
                                "name": .string("tron-core"), "purpose": .string("Tron core extension"),
                                "tools": .array([.string("knowledge")]), "commands": .array([]),
                            ])]),
                            "connections": .array([]),
                        ])))
                    }
                    try await Task.sleep(for: .milliseconds(80))
                    let methods = await socket.sentFrames().compactMap {
                        try? JSONDecoder.gateway.decode(SettingsRequest.self, from: $0).method
                    }.filter { $0.hasPrefix("packages.") || $0.hasPrefix("modules.") }
                    XCTAssertEqual(methods, capabilities.contains("modules.v1")
                        ? ["packages.list", "packages.checkUpdates", "modules.list"]
                        : ["packages.list", "packages.checkUpdates"],
                        "A Gateway without modules.v1 is never asked for a module list it cannot answer")
                }
            } catch {
                await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
                throw error
            }
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
        }
    }

    func testExtensionsSheetReadsProvidesFromThePackageListingAlone() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"), "gatewayVersion": .string("1.0.0"), "piVersion": .string("1.0.0"),
            "protocolVersion": .number(5), "minProtocolVersion": .number(5), "machineId": .string("machine"),
            "machineName": .string("Mac"), "gatewayChannel": .string("stable"),
            "capabilities": .array([.string("sessions.v1")]),
        ])))
        do {
            try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"), token: "token")
            try await withHost(ExtensionsSettingsView(projectCWD: nil).environment(model).tronPresentation().tronSettingsLayout(),
                               size: CGSize(width: 440, height: 800)) { _ in
                let listing = try await request(socket, method: "packages.list")
                await socket.enqueue(try reply(listing.id, .object([
                    "packages": .array([.object([
                        "source": .string("npm:pi-subagents"),
                        "scope": .string("user"),
                        "filtered": .bool(false),
                        "installedPath": .string("/packages/pi-subagents"),
                        "provides": .object([
                            "skills": .array([.string("repo-optimizer")]),
                            "prompts": .array([]),
                            "themes": .array([]),
                            "subagents": .array([.string("worker")]),
                            "tools": .array([.string("subagent")]),
                            "commands": .array([.string("goal")]),
                        ]),
                    ])]),
                    "resources": .object([
                        "extensions": .array([]), "skills": .array([]),
                        "prompts": .array([]), "themes": .array([]),
                    ]),
                    "providesDiagnostic": .string("tools and commands are unavailable: boom"),
                ])))
                let updates = try await request(socket, method: "packages.checkUpdates")
                await socket.enqueue(try reply(updates.id, .object(["updates": .array([])])))
                try await Task.sleep(for: .milliseconds(80))
                let methods = await socket.sentFrames().compactMap {
                    try? JSONDecoder.gateway.decode(SettingsRequest.self, from: $0).method
                }.filter { $0.hasPrefix("packages.") || $0.hasPrefix("modules.") }
                XCTAssertEqual(methods, ["packages.list", "packages.checkUpdates"],
                               "Provides arrives on the existing package read; the sheet opens nothing else")
                let inventory = model.packageInventory(for: .global)
                XCTAssertEqual(inventory?.packages.first?.provides?.tools, ["subagent"])
                XCTAssertEqual(inventory?.packages.first?.provides?.subagents, ["worker"])
                XCTAssertEqual(inventory?.providesDiagnostic, "tools and commands are unavailable: boom")
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    func testHooksSheetReadsTheSelectedScopeOnlyWhenTheGatewayAdvertisesHooks() async throws {
        let projectDirectory = "/tmp/tron-hooks-project"
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"), "gatewayVersion": .string("1.0.0"), "piVersion": .string("1.0.0"),
            "protocolVersion": .number(5), "minProtocolVersion": .number(5), "machineId": .string("machine"),
            "machineName": .string("Mac"), "gatewayChannel": .string("stable"),
            "capabilities": .array([.string("sessions.v1"), .string("hooks.v1")]),
        ])))
        do {
            try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"), token: "token")
            try await withHost(HooksSettingsView(projectCWD: projectDirectory).environment(model).tronPresentation().tronSettingsLayout(),
                               size: CGSize(width: 440, height: 800)) { _ in
                let listing = try await request(socket, method: "hooks.list")
                // Every Project is the default scope, so the request carries no cwd.
                let hooksParams = await frame(socket, method: "hooks.list")?.objectValue?["params"]?.objectValue
                XCTAssertNil(hooksParams?["cwd"], "Every Project must ask the Gateway without a project path")
                // The untrusted-project note reads the same trust state the
                // Project Trust row reads, for this project.
                let inspection = try await request(socket, method: "trust.inspect")
                let inspectionCwd = await frame(socket, method: "trust.inspect")?.objectValue?["params"]?.objectValue?["cwd"]?.stringValue
                XCTAssertEqual(inspectionCwd, projectDirectory)
                await socket.enqueue(try reply(inspection.id, .object([
                    "cwd": .string(projectDirectory), "requiresDecision": .bool(true), "savedDecision": .bool(false),
                    "defaultDecision": .string("ask"), "effectiveDecision": .bool(false),
                ])))
                await socket.enqueue(try reply(listing.id, .object([
                    "extensions": .array([.object([
                        "name": .string("tron-notify"), "path": .string("<inline:tron-notify>"),
                        "resolvedPath": .string("<inline:tron-notify>"), "scope": .string("temporary"),
                        "source": .string("inline"), "origin": .string("top-level"),
                        "tools": .array([.string("notify")]), "commands": .array([]),
                        "handlers": .array([.object(["event": .string("agent_end"), "count": .number(1)])]),
                    ])]),
                    "extensionLoadErrors": .array([]),
                    "hookInventory": .object([:]),
                ])))
                try await Task.sleep(for: .milliseconds(80))
                // The note's decision itself is asserted by
                // HooksSettingsPresentationTests: this harness renders SwiftUI
                // text without UIKit labels, so only the read that feeds the
                // note is observable here.
                let settledCwd = await frame(socket, method: "trust.inspect")?.objectValue?["params"]?.objectValue?["cwd"]?.stringValue
                XCTAssertEqual(settledCwd, projectDirectory, "The note's input is the current project's trust state")
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    func testHooksSheetWithoutTheCapabilityAsksForNothing() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"), "gatewayVersion": .string("1.0.0"), "piVersion": .string("1.0.0"),
            "protocolVersion": .number(5), "minProtocolVersion": .number(5), "machineId": .string("machine"),
            "machineName": .string("Mac"), "gatewayChannel": .string("stable"),
            "capabilities": .array([.string("sessions.v1")]),
        ])))
        do {
            try await model.connectHostedGateway(profile: GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"), token: "token")
            try await withHost(HooksSettingsView(projectCWD: nil).environment(model).tronPresentation().tronSettingsLayout(),
                               size: CGSize(width: 440, height: 800)) { _ in
                try await Task.sleep(for: .milliseconds(120))
                let methods = await socket.sentFrames().compactMap {
                    try? JSONDecoder.gateway.decode(SettingsRequest.self, from: $0).method
                }
                XCTAssertFalse(methods.contains("hooks.list"),
                               "A Gateway without hooks.v1 is never asked for an inventory it cannot answer")
                XCTAssertFalse(methods.contains("trust.inspect"),
                               "Without a project path there is no project trust state to explain")
            }
        } catch {
            await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
            throw error
        }
        await model.teardown(); await client.close(); try? FileManager.default.removeItem(at: root)
    }

    private struct SettingsRequest: Decodable { let id: String; let method: String }

    /// The complete sent frame for one method, for asserting the request's
    /// params rather than only its method.
    private func frame(_ socket: ScriptedGatewaySocket, method: String) async -> JSONValue? {
        for data in await socket.sentFrames() {
            let value = try? JSONDecoder.gateway.decode(JSONValue.self, from: data)
            if value?.objectValue?["method"]?.stringValue == method { return value }
        }
        return nil
    }
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

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func image<Content: View>(_ host: UIHostingController<Content>) -> UIImage {
        UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
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

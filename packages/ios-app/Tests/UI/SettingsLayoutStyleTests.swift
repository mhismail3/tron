import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class SettingsLayoutStyleTests: XCTestCase {
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
                    TronSettingsGroup("Models and Defaults", accent: .tronPurple) {
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
                let catalog = try await request(socket, count: 3)
                XCTAssertEqual(catalog.method, "session.list")
                await socket.enqueue(try reply(catalog.id, .object(["sessions": .array([]), "listRevision": .number(1)])))
                await reconciliation?.value
                let refreshed = try await request(socket, count: 4)
                XCTAssertEqual(refreshed.method, "packages.list", "Foreground must re-read the visible page without tapping Retry")
                await socket.enqueue(try reply(refreshed.id, .object(["packages": .array([]), "resources": .object([
                    "extensions": .array([]), "skills": .array([]), "prompts": .array([]), "themes": .array([])
                ])])))
                let updates = try await request(socket, count: 5)
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
    private struct SettingsRequest: Decodable { let id: String; let method: String }
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

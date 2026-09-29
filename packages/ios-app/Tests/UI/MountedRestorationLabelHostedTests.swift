import SwiftUI
import XCTest
@testable import TronMobile
@testable import TronMobileCore

/// The production connection label mounted over the real reconnect path while
/// the Gateway answers this restoration's `session.open` slowly (C-2).
///
/// SwiftUI paints `Text` without `UILabel` and installs no
/// `accessibilityElements` in this version, so the assertion is on the exact
/// `DashboardServerConnectionState` the production `GatewayConnectionStatusBadge`
/// renders (`GatewayConnectionStatusBadge` draws `state.label`). The retained
/// capture is the visual artifact; the reported state is the badge's own input.
@MainActor
final class MountedRestorationLabelHostedTests: XCTestCase {

    func testSlowMountedRestorationNeverLabelsTheLiveSocketReconnecting() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) { @MainActor in
            try await self.performSlowRestoration()
        }
    }

    private func performSlowRestoration() async throws {
        let suiteName = "MountedRestorationLabelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = GatewayProfile(
            id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
        let factory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: factory.factory)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let clock = ManualClock()
        let model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot),
            clock: clock.clock,
            reconnectDelayPolicy: ReconnectDelayPolicy(nextUnitInterval: { 0.5 }),
            profileTokenLookup: { _ in "token" }
        )
        let controller = UIHostingController(
            rootView: ConnectionLabelSurface(model: model, profileID: profile.id)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        do {
            await sockets[0].enqueue(hello())
            try await model.connectHostedGateway(profile: profile, token: "token")
            let snapshot = try SessionScenarioBuilder(seed: 61_204).openingTail(targetEncodedBytes: 4_096)
            model.installHostedSubscribedSnapshot(snapshot)
            try assertLabel("Connected", model: model, profileID: profile.id, controller: controller)

            await model.enteredBackground().value
            await model.becameActive()?.value
            try await sockets[1].waitUntilSent(count: 1)
            await sockets[1].enqueue(hello())

            // The replacement handshake succeeded; the Gateway is slow on this
            // restoration's `session.open` and has answered nothing yet.
            var index = 1
            var openID: String?
            while openID == nil {
                try await sockets[1].waitUntilSent(count: index + 1)
                let request = try requestFrame(await sockets[1].sentFrames()[index])
                index += 1
                switch request.method {
                case "session.open": openID = request.id
                case "session.list", "notification.inbox.list": break // Optional owners.
                default:
                    XCTFail("Unexpected request before mounted restoration: \(request.method)")
                    throw CancellationError()
                }
            }
            let activeConnectionID = await client.activeConnectionID()
            XCTAssertNotNil(activeConnectionID, "The socket that admitted the restoration is live")
            try assertLabel("Connected", model: model, profileID: profile.id, controller: controller)

            // The restoration outlasts its grace: the chat shows its own
            // catch-up treatment, and the label is still the live socket.
            clock.advance(by: .seconds(3))
            for _ in 0..<400 where !model.noticeCenter.notices.contains(where: {
                $0.replacement?.key == .sessionCatchUp
            }) {
                try await Task.sleep(for: .milliseconds(5))
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
            }
            XCTAssertEqual(
                model.noticeCenter.notices.first { $0.replacement?.key == .sessionCatchUp }?.title,
                SessionPresentationStore.sessionCatchUpNotice
            )
            try assertLabel("Connected", model: model, profileID: profile.id, controller: controller)
            attachCapture(controller, name: "mounted-restoration-connected-label")

            // Answer the restoration: the treatment retires, the label does not move.
            let open = try XCTUnwrap(openID)
            await sockets[1].enqueue(response(id: open, result: .object([
                "session": try JSONValue.encode(snapshot),
                "syncToken": .string("hosted-restoration-sync"),
                "subscriptionToken": .string("hosted-restoration-subscription"),
            ])))
            var syncID: String?
            while syncID == nil {
                try await sockets[1].waitUntilSent(count: index + 1)
                let request = try requestFrame(await sockets[1].sentFrames()[index])
                index += 1
                switch request.method {
                case "session.sync": syncID = request.id
                case "session.list", "notification.inbox.list": break // Optional owners.
                default:
                    XCTFail("Unexpected request after mounted restoration: \(request.method)")
                    throw CancellationError()
                }
            }
            await sockets[1].enqueue(response(id: syncID!, result: .object(["synchronized": .bool(true)])))
            for _ in 0..<400 where model.isReconcilingForeground {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(model.isReconcilingForeground)
            XCTAssertFalse(model.noticeCenter.notices.contains { $0.replacement?.key == .sessionCatchUp })
            try assertLabel("Connected", model: model, profileID: profile.id, controller: controller)
            await model.teardown()
            await client.close()
        } catch {
            await model.teardown()
            await client.close()
            throw error
        }
    }

    /// The label the badge renders, laid out natively, at this exact moment.
    private func assertLabel(
        _ expected: String,
        model: AppModel,
        profileID: String,
        controller: UIHostingController<ConnectionLabelSurface>
    ) throws {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let state = model.dashboardServerState(for: profileID)
        XCTAssertEqual(state.label, expected)
        XCTAssertEqual(model.connectionState, .connected)
    }

    private func hello() -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"),
            "gatewayVersion": .string("1.0.0"),
            "piVersion": .string("1.0.0"),
            "protocolVersion": .number(6),
            "minProtocolVersion": .number(6),
            "machineId": .string("machine"),
            "machineName": .string("Mac"),
            "capabilities": .array([.string("sessions.v1")]),
            "gatewayChannel": .string("stable"),
        ]))
    }

    private func requestFrame(_ data: Data) throws -> (id: String, method: String) {
        let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        return (
            try XCTUnwrap(value.objectValue?["id"]?.stringValue),
            try XCTUnwrap(value.objectValue?["method"]?.stringValue)
        )
    }

    private func response(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result,
        ]))
    }

    private func attachCapture(_ controller: UIViewController, name: String) {
        // The hosted window is not in a foreground scene, so render the
        // mounted view's own layer rather than snapshotting the window.
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The production label view over the model's own dashboard state.
private struct ConnectionLabelSurface: View {
    let model: AppModel
    let profileID: String

    var body: some View {
        GatewayConnectionStatusBadge(state: model.dashboardServerState(for: profileID))
    }
}

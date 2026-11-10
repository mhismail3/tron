import Foundation
import SwiftUI
@testable import TronMobileCore
import UIKit
@testable import TronMobile

@MainActor
final class ProfileGatewayFixture {
    typealias Handler = @MainActor (_ params: JSONValue?) throws -> JSONValue

    let socket = ScriptedGatewaySocket()
    let client: GatewayClient
    let model: AppModel
    let profile = GatewayProfile(
        id: "profile-fixture", label: "Fixture Mac", host: "gateway.test", port: 9_847,
        machineId: "fixture-machine", deviceId: "fixture-device"
    )
    let root: URL
    private let suiteName: String
    private let defaults: UserDefaults
    private var handlers: [String: Handler] = [:]
    private var responder: Task<Void, Never>?
    private(set) var unansweredMethods: [String] = []
    private var window: UIWindow?

    static let ledgerNames = [
        "transport.frames", "transport.bytes", "rpc.requests", "rpc.unanswered", "rpc.resynchronizations",
    ]

    init(composerDraftStore: ((URL) -> ComposerDraftStore)? = nil) throws {
        suiteName = "tron-profile.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ProfileScenarioError.notReady("cannot create an isolated defaults suite")
        }
        self.defaults = defaults
        root = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(try JSONEncoder.gateway.encode(
            GatewayProfileDocument(profiles: [profile], selectedProfileID: profile.id)
        ), forKey: "gatewayProfiles.v2")
        client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let draftRoot = root.appending(path: "drafts", directoryHint: .isDirectory)
        model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: root.appending(path: "cache", directoryHint: .isDirectory)),
            composerDraftStore: composerDraftStore?(draftRoot) ?? ComposerDraftStore(root: draftRoot)
        )
        for name in Self.ledgerNames { ProfileScenarioLedger.shared.add(name, 0) }
    }

    func handle(_ method: String, _ handler: @escaping Handler) { handlers[method] = handler }

    func connect(capabilities: [String] = ["sessions.v1"]) async throws {
        let hello: JSONValue = .object([
            "type": .string("hello"), "gatewayVersion": .string("1.0.0"), "piVersion": .string("1.0.0"),
            "protocolVersion": .number(8), "minProtocolVersion": .number(8),
            "machineId": .string(profile.machineId), "machineName": .string(profile.label),
            "gatewayChannel": .string("stable"), "capabilities": .array(capabilities.map(JSONValue.string)),
        ])
        await socket.enqueue(try JSONEncoder.gateway.encode(hello))
        try await model.connectHostedGateway(profile: profile, token: "fixture-token")
        startResponder()
    }

    private func startResponder() {
        let socket = socket
        responder = Task { @MainActor [weak self] in
            var index = 1
            while !Task.isCancelled {
                do { try await socket.waitUntilSent(count: index + 1) } catch { return }
                let frames = await socket.sentFrames()
                guard let self, frames.indices.contains(index) else { return }
                let data = frames[index]
                index += 1
                guard let request = try? JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue,
                      let method = request["method"]?.stringValue,
                      let id = request["id"]?.stringValue else { continue }
                ProfileScenarioLedger.shared.add("rpc.requests")
                if method == "session.open" || method == "session.sync" {
                    ProfileScenarioLedger.shared.add("rpc.resynchronizations")
                }
                var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id)]
                if let handler = handlers[method], let result = try? handler(request["params"]) {
                    response["ok"] = .bool(true)
                    response["result"] = result
                } else {
                    unansweredMethods.append(method)
                    ProfileScenarioLedger.shared.add("rpc.unanswered")
                    print("TRON_PROFILE_UNSCRIPTED_RPC method=\(method)")
                    response["ok"] = .bool(false)
                    response["error"] = .object([
                        "code": .string("fixture_unsupported"), "message": .string(method), "retryable": .bool(false),
                    ])
                }
                guard let encoded = try? JSONEncoder.gateway.encode(JSONValue.object(response)) else { continue }
                await socket.enqueue(encoded)
            }
        }
    }

    func deliver(topic: String, sessionID: String?, payload: JSONValue) async throws {
        var frame: [String: JSONValue] = ["type": .string("event"), "topic": .string(topic), "payload": payload]
        if let sessionID { frame["sessionId"] = .string(sessionID) }
        try await deliver(frame: JSONEncoder.gateway.encode(JSONValue.object(frame)))
    }

    func deliver(frame data: Data) async throws {
        ProfileScenarioLedger.shared.add("transport.frames")
        ProfileScenarioLedger.shared.add("transport.bytes", data.count)
        await socket.enqueue(data)
    }

    func mount<Content: View>(_ content: Content) throws -> UIHostingController<AnyView> {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw ProfileScenarioError.notReady("the hosted test app has no window scene")
        }
        let host = UIHostingController(rootView: AnyView(content
            .environment(model)
            .environment(\.tronPresentationActivityCoordinator, PresentationActivityCoordinator())
            .environment(\.scenePhase, .active)
            .tronPresentation()))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        self.window = window
        return host
    }

    func teardown() async {
        responder?.cancel()
        responder = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        await model.teardown()
        await client.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
func profileWaitUntil(
    _ description: String,
    timeout: Duration = .seconds(20),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ProfileScenarioError.notReady(description) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
func profileViews<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { profileViews(type, in: $0) }
}

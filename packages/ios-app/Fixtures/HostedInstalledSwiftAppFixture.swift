#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Only test entry/credentials are synthetic. Pairing, the Pi tool install,
/// installed snapshot, receipt owner, interpreter and runner are production.
struct HostedInstalledSwiftAppFixture: View {
    @State private var model: AppModel
    @State private var status = "Connecting"
    @State private var ready = false
    @State private var opening = false
    @State private var document: InstalledSwiftAppSession?
    @PresentationState private var launch: SwiftAppLaunch?

    init() {
        let memory = InstalledFixtureProfiles()
        _model = State(initialValue: AppModel(profiles: GatewayProfileStore(metadata: memory, tokens: memory)))
    }

    var body: some View {
        TronPresentationSurface(id: "hosted-installed-swift-app") {
            VStack(spacing: TronSpacing.large) {
                Text(status).accessibilityIdentifier("installed.status")
                Button("Open installed app") { Task { await open() } }
                    .disabled(!ready || opening)
                    .accessibilityIdentifier("installed.open")
                if let document {
                    Text(document.failure ?? (document.hasUnsavedChanges ? "Unsaved changes" : "Saved revision \(document.revision)"))
                        .accessibilityIdentifier("installed.saveStatus")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .tronManagedSheet(item: $launch, identity: { "installed.run.\($0.id)" }) { launch in
                SwiftAppRunnerSheet(launch: launch)
            }
        }
        .environment(model)
        .tronPresentation()
        .task { await bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let port = environment["TRON_E2E_PORT"].flatMap(Int.init),
                  let code = environment["TRON_E2E_CODE"], let workspace = environment["TRON_E2E_WORKSPACE"] else {
                throw InstalledSwiftAppFailure("Run this fixture through the real Gateway UI harness.")
            }
            await model.becameActive()?.value
            try await model.pair(PairingInvitation(host: "127.0.0.1", port: port, code: code,
                machineId: "tron-ios-e2e", label: "Persistence Gateway"))
            struct Created: Decodable { let sessionId: String }
            let created: Created = try await model.client.request("session.create", JSONValue.object([
                "cwd": .string(workspace), "commandId": .string(UUID().uuidString.lowercased()),
            ]))
            let opened: GatewaySessionOpenResponse = try await model.client.request("session.open", JSONValue.object(["sessionId": .string(created.sessionId)]))
            let _: JSONValue = try await model.client.request("session.sync", JSONValue.object([
                "sessionId": .string(created.sessionId), "syncToken": .string(opened.syncToken),
            ]))
            let _: JSONValue = try await model.client.request("settings.change", JSONValue.object([
                "commandId": .string(UUID().uuidString.lowercased()),
                "target": .object(["kind": .string("session"), "sessionId": .string(created.sessionId)]),
                "fence": .object(["runtimeGeneration": .string(opened.session.runtimeGeneration),
                    "model": try opened.session.model.map { try JSONValue.encode($0) } ?? .null]),
                "changes": .array([.object(["key": .string("model.ref[role=chat]"), "layer": .string("session"),
                    "op": .string("set"), "value": .object(["provider": .string("tron-e2e"), "id": .string("e2e-model")])])]),
            ]))
            let _: JSONValue = try await model.client.request("session.prompt", JSONValue.object([
                "sessionId": .string(created.sessionId), "text": .string("INSTALLED-SWIFT-APP-PERSISTENCE"),
                "uploadIds": .array([]), "commandId": .string(UUID().uuidString.lowercased()),
            ]))
            let deadline = ContinuousClock.now + .seconds(15)
            while true {
                do {
                    let _: JSONValue = try await model.client.request("apps.get", JSONValue.object(["appId": .string("persistence-proof")]))
                    break
                } catch let failure as GatewayFailure where failure.code == "not_found" && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            status = "Ready"
            ready = true
        } catch { status = String(describing: error) }
    }

    @MainActor
    private func open() async {
        opening = true
        defer { opening = false }
        do {
            guard let profile = model.profiles.selected else { throw InstalledSwiftAppFailure("No selected Gateway") }
            let document = try await model.installedApps.open(appID: "persistence-proof", profileID: profile.id)
            self.document = document
            launch = SwiftAppLaunch(name: document.snapshot.app.name, source: document.snapshot.source,
                linkHost: profile.host, installed: document)
        } catch { status = String(describing: error) }
    }
}

private final class InstalledFixtureProfiles: GatewayProfileMetadataStoring, GatewayTokenStoring {
    private var metadata: GatewayProfileDocument?
    private var tokens: [String: String] = [:]
    func load() throws -> GatewayProfileDocument? { metadata }
    func save(_ document: GatewayProfileDocument) throws { metadata = document }
    func save(_ token: String, profileID: String) throws { tokens[profileID] = token }
    func read(profileID: String) throws -> String? { tokens[profileID] }
    func delete(profileID: String) throws { tokens.removeValue(forKey: profileID) }
}
#endif

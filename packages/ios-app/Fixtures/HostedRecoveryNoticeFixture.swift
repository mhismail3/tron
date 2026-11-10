#if HOSTED_TEST
import SwiftUI
import TronMobileCore

struct HostedRecoveryNoticeFixture: View {
    @State private var model: AppModel
    @State private var activity = PresentationActivityCoordinator()
    @State private var retries = 0
    @Environment(\.colorScheme) private var colorScheme

    init() {
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(GatewayProfile(id: "recovery-notice", label: "Studio Mac", host: "recovery-notice.invalid",
                                          port: 9847, machineId: "recovery-notice-machine"), token: "fixture-only-token")
        let root = FileManager.default.temporaryDirectory.appending(path: "recovery-notice-fixture-\(UUID().uuidString)")
        _model = State(initialValue: AppModel(profiles: profiles, cache: SnapshotCache(root: root.appending(path: "cache"))))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Retries \(retries)").accessibilityIdentifier("recovery-notice-retries")
                Button("Classify again") { model.lifecycleConnectionFailurePresentationDidChange() }
                    .accessibilityIdentifier("recovery-notice-classify")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if model.isConnectionRecoveryVisible {
                        ChatRecoveryStatusLine(status: .waitingForConnection) { retries += 1 }
                    } else {
                        Text("Studio Mac").accessibilityIdentifier("recovery-notice-title")
                    }
                }
            }
        }
        .background {
            InAppNoticeWindowInstaller(model: model, colorScheme: colorScheme, presentationActivity: activity)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .environment(model)
        .tronPresentation()
        .task { await model.start() }
    }
}

@MainActor
enum HostedKeychainLockedFixture {
    struct Locked: Error {}

    final class Store: GatewayProfileMetadataStoring, GatewayTokenStoring {
        var locked = false
        private var document: GatewayProfileDocument?
        private var tokens: [String: String] = [:]
        func load() throws -> GatewayProfileDocument? { document }
        func save(_ document: GatewayProfileDocument) throws { self.document = document }
        func save(_ token: String, profileID: String) throws { tokens[profileID] = token }
        func read(profileID: String) throws -> String? {
            if locked { throw Locked() }
            return tokens[profileID]
        }
        func delete(profileID: String) throws { tokens.removeValue(forKey: profileID) }
    }

    static let store = Store()

    static let model: AppModel = {
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(GatewayProfile(id: "keychain-locked", label: "Studio Mac", host: "keychain-locked.invalid",
                                          port: 9847, machineId: "keychain-locked-machine"), token: "fixture-only-token")
        store.locked = true
        let root = FileManager.default.temporaryDirectory.appending(path: "keychain-locked-fixture-\(UUID().uuidString)")
        return AppModel(profiles: profiles, cache: SnapshotCache(root: root.appending(path: "cache")))
    }()

    struct ConnectionState: View {
        var body: some View {
            Text(Self.describe(HostedKeychainLockedFixture.model.connectionState))
                .font(.caption2)
                .accessibilityIdentifier("keychain-locked-state")
                .allowsHitTesting(false)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    HostedKeychainLockedFixture.store.locked = false
                }
        }

        private static func describe(_ state: AppModel.ConnectionState) -> String {
            switch state {
            case .offline(let reason): "offline: \(reason)"
            default: "\(state)"
            }
        }
    }
}
#endif

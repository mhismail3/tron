#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// A real recovery episode (#2273): the selected Mac never resolves, so the production
/// lifecycle schedules its reconnects, and after the grace `AppModel` posts its recovery
/// notice and the route shows `ChatRecoveryStatusLine`, as `ChatView` does. "Classify again"
/// calls the lifecycle's failure-presentation callback the way a reconnect attempt whose
/// failure is newly classified does, with the visible text unchanged.
struct HostedRecoveryNoticeFixture: View {
    @State private var model: AppModel
    @State private var activity = PresentationActivityCoordinator()
    @State private var retries = 0
    @Environment(\.colorScheme) private var colorScheme

    init() {
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        // `.invalid` never resolves, so every attempt fails and recovery begins.
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
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    HostedKeychainLockedFixture.store.locked = false
                }
        }
        .environment(model)
        .tronPresentation()
        .task { await model.start() }
    }
}

/// #2296 item 15: the selected profile's Keychain token cannot be read until the
/// app first leaves the foreground, as on a launch before the device's first
/// unlock. The production scene runs over it; the overlay counts token reads
/// and unlocks the store when the app enters the background.
@MainActor
enum HostedKeychainLockedFixture {
    struct Locked: Error {}

    @Observable
    final class Store: GatewayProfileMetadataStoring, GatewayTokenStoring {
        var reads = 0
        var locked = false
        private var document: GatewayProfileDocument?
        private var tokens: [String: String] = [:]
        func load() throws -> GatewayProfileDocument? { document }
        func save(_ document: GatewayProfileDocument) throws { self.document = document }
        func save(_ token: String, profileID: String) throws { tokens[profileID] = token }
        func read(profileID: String) throws -> String? {
            reads += 1
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
        store.reads = 0
        let root = FileManager.default.temporaryDirectory.appending(path: "keychain-locked-fixture-\(UUID().uuidString)")
        return AppModel(profiles: profiles, cache: SnapshotCache(root: root.appending(path: "cache")))
    }()

    struct ReadCount: View {
        var body: some View {
            Text("Keychain reads \(HostedKeychainLockedFixture.store.reads)")
                .font(.caption2)
                .accessibilityIdentifier("keychain-locked-reads")
                .allowsHitTesting(false)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    HostedKeychainLockedFixture.store.locked = false
                }
        }
    }
}
#endif

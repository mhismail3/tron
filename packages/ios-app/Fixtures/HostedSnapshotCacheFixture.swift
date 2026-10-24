#if HOSTED_TEST
import CryptoKit
import Foundation
import SwiftUI
import TronMobileCore

/// Hosted-process/filesystem contract driver. Reports read actual files and
/// public model/catalog values, never SnapshotCache's private generations.
struct HostedSnapshotCacheFixture: View {
    @State private var driver = SnapshotCacheFixtureDriver()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(driver.phase).accessibilityIdentifier("cache.phase")
                Text(String(ProcessInfo.processInfo.processIdentifier)).accessibilityIdentifier("cache.pid")
                Text(driver.model.profiles.selected?.id ?? "<none>").accessibilityIdentifier("cache.profile")
                Text(driver.model.sessions.compactMap(\.name).joined(separator: "|").isEmpty
                     ? "<none>" : driver.model.sessions.compactMap(\.name).joined(separator: "|"))
                    .accessibilityIdentifier("cache.catalog")
                Text(driver.model.archivedSessionCount.map(String.init) ?? "<none>")
                    .accessibilityIdentifier("cache.catalog-archive")
                Text(driver.runtimeHasTranscript ? "present" : "absent").accessibilityIdentifier("cache.runtime-transcript")
                Text(driver.report).font(.system(size: 11, design: .monospaced)).lineLimit(3)
                    .accessibilityLabel(driver.report).accessibilityIdentifier("cache.file-report")
                Text(driver.clockHeld ? "held" : "idle").accessibilityIdentifier("cache.delay")
                Text(driver.saveHeld ? "held" : "idle").accessibilityIdentifier("cache.save")
                Text(driver.completion).accessibilityIdentifier("cache.completion")
                Text(driver.loadedNames).accessibilityIdentifier("cache.kernel-loads")
                Button("Send summary") { Task { await driver.sendSummary() } }.accessibilityIdentifier("cache.summary")
                Button("Background API") { driver.background() }.accessibilityIdentifier("cache.background")
                Button("Switch profile") { driver.switchProfile() }.accessibilityIdentifier("cache.switch")
                Button("Release write") { driver.saveGate.release() }.accessibilityIdentifier("cache.release")
                Button("Forget then stale save") { Task { await driver.forgetAndSaveLate() } }.accessibilityIdentifier("cache.forget")
                Button("Inspect files") { driver.inspectFiles() }.accessibilityIdentifier("cache.inspect")
                Button("Clean fixture") { Task { await driver.cleanup() } }.accessibilityIdentifier("cache.cleanup")
            }.padding()
        }
        .task { await driver.start() }
        .task { for await _ in driver.delay.entries { driver.clockHeld = true } }
        .task { for await _ in driver.saveGate.entries { driver.saveHeld = true } }
        .task { for await _ in driver.saveGate.completions { driver.inspectFiles() } }
    }
}

@Observable @MainActor
private final class SnapshotCacheFixtureDriver {
    let model: AppModel
    let saveGate: SnapshotCacheFixtureSaveGate
    let delay: SnapshotCacheFixtureDelay
    private let cache: SnapshotCache
    private let client: GatewayClient
    private let gateway: SnapshotCacheFixtureGateway
    private let root: URL
    private let cacheRoot: URL
    private let mode: String
    private let first = GatewayProfile(id: "fixture/profile:first", label: "Cache first", host: "cache-first.example.test",
        port: 9847, machineId: "cache-fixture-machine", deviceId: "fixture-device")
    private let second = GatewayProfile(id: "fixture/profile:second", label: "Cache second", host: "cache-second.example.test",
        port: 9847, machineId: "cache-fixture-machine", deviceId: "fixture-device")
    private var started = false
    private var lifecycleJob: Task<Void, Never>?
    var phase = "starting"
    var report = "{}"
    var loadedNames = "<none>"
    var clockHeld = false
    var saveHeld = false
    var completion = "idle"

    init() {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ key: String) -> String? { args.drop(while: { $0 != key }).dropFirst().first }
        let token = UUID(uuidString: argument("-snapshot-cache-token") ?? "") ?? UUID()
        mode = argument("-snapshot-cache-mode") ?? "live"
        root = FileManager.default.temporaryDirectory.appending(path: "snapshot-cache-lock-\(token.uuidString)", directoryHint: .isDirectory)
        cacheRoot = root.appending(path: "snapshots", directoryHint: .isDirectory)
        let saveGate = SnapshotCacheFixtureSaveGate(); self.saveGate = saveGate
        let delay = SnapshotCacheFixtureDelay(); self.delay = delay
        let clock = MonotonicClock(now: MonotonicClock.continuous.now,
            sleep: { try await delay.sleep($0) }, gridOrigin: ContinuousClock.now)
        let gateway = SnapshotCacheFixtureGateway(offline: mode != "live")
        self.gateway = gateway
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in SnapshotCacheFixtureSocket(gateway: gateway) })
        self.client = client
        let cache = SnapshotCache(root: cacheRoot, performanceSignposts: saveGate); self.cache = cache
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(first, token: "fixture-only-token")
        model = AppModel(client: client, profiles: profiles, cache: cache, clock: clock,
                         composerDraftStore: ComposerDraftStore(root: root.appending(path: "drafts")))
    }

    var runtimeHasTranscript: Bool {
        guard let snapshot = model.selectedSnapshot, let data = try? JSONEncoder.gateway.encode(snapshot) else { return false }
        return String(decoding: data, as: UTF8.self).contains(SnapshotCacheFixtureGateway.transcriptMarker)
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            if mode == "generations" {
                await cache.save(profileID: first.id, generation: 20,
                    sessions: [SnapshotCacheFixtureGateway.row(name: "Generation winner"), SnapshotCacheFixtureGateway.row(archived: true)], archivedCount: 7)
                await cache.save(profileID: first.id, generation: 19,
                    sessions: [SnapshotCacheFixtureGateway.row(name: "Stale generation")], archivedCount: 1)
                await cache.save(profileID: second.id, generation: 1,
                    sessions: [SnapshotCacheFixtureGateway.row(name: "Other profile")], archivedCount: 3)
                let a = await cache.load(profileID: first.id)
                let b = await cache.load(profileID: second.id)
                loadedNames = (a.sessions + b.sessions).compactMap(\.name).joined(separator: "|")
                inspectFiles(); phase = "generation-ready"
                return
            }
            if ["v3", "v4", "future", "corrupt", "oversized"].contains(mode) {
                await cache.save(profileID: first.id, sessions: [SnapshotCacheFixtureGateway.row()], archivedCount: 7)
                try prepareEnvelope()
            }
            await model.start()
            if mode == "live" {
                _ = await model.refreshSessions()
                _ = try await model.openSessionPresentation("cache-live")
            }
            inspectFiles()
            phase = "ready"
        } catch { phase = "error: \(error)" }
    }

    private func file(_ profileID: String) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appending(path: "\(digest).json")
    }

    private func prepareEnvelope() throws {
        let url = file(first.id)
        if mode == "corrupt" { try Data("{invalid-json".utf8).write(to: url); return }
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        if mode == "v3" { document["version"] = 3 }
        if mode == "future" { document["version"] = 99 }
        if mode == "oversized" {
            document["padding"] = ""
            let overhead = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).count
            document["padding"] = String(repeating: "x", count: SnapshotCachePolicy.maximumEncodedBytes + 1 - overhead)
        }
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    func inspectFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        var documents: [[String: Any]] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let rows = document?["sessions"] as? [[String: Any]] ?? []
            documents.append(["file": url.lastPathComponent, "bytes": data.count,
                "version": document?["version"] ?? -1, "archivedCount": document?["archivedCount"] ?? -1,
                "names": rows.compactMap { $0["name"] as? String }, "ids": rows.compactMap { $0["id"] as? String },
                "hasTranscript": String(decoding: data, as: UTF8.self).contains(SnapshotCacheFixtureGateway.transcriptMarker),
                "hasTranscriptKey": document?["transcript"] != nil || rows.contains { $0["transcript"] != nil || $0["messages"] != nil }])
        }
        let object: [String: Any] = ["documents": documents, "firstExists": FileManager.default.fileExists(atPath: file(first.id).path)]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            report = String(decoding: data, as: UTF8.self)
        }
    }

    func sendSummary() async {
        do {
            await delay.arm()
            saveGate.arm()
            try await gateway.summary()
        } catch { phase = "error: \(error)" }
    }

    func background() {
        completion = "pending"
        lifecycleJob = Task { @MainActor [self] in
            await model.enteredBackground().value
            completion = "done"
            inspectFiles()
        }
    }

    func switchProfile() {
        completion = "pending"
        lifecycleJob = Task { @MainActor [self] in
            do {
                try model.profiles.save(second, token: "fixture-only-token", selecting: false)
                // Only the selected fake socket is in play; do not start a
                // secondary dashboard URLSession client for the retired input.
                try model.profiles.setEnabled(false, for: first)
                await model.switchGateway(second)
                completion = "done"
                inspectFiles()
            } catch { phase = "error: \(error)" }
        }
    }

    func forgetAndSaveLate() async {
        await model.forgetGateway(first)
        await cache.save(profileID: first.id, generation: Int.max,
            sessions: [SnapshotCacheFixtureGateway.row(name: "Late after removal")])
        inspectFiles()
        phase = "forgotten"
    }

    func cleanup() async {
        saveGate.release()
        await delay.release()
        await lifecycleJob?.value
        lifecycleJob = nil
        await model.enteredBackground().value
        await client.close()
        // A relaunch deliberately retains the UUID root; this explicit final
        // action owns only that fixture root, never ordinary application data.
        try? FileManager.default.removeItem(at: root)
        phase = "cleaned"
    }
}
#endif

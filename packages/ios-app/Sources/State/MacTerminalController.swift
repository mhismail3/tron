import CryptoKit
import Foundation
import MacTerminalSSH
import Observation
import TronMobileCore

/// Enrollment facts only. Once enrolled, connect and reconnect never call the Gateway.
struct MacTerminalStatus: Decodable, Equatable, Sendable {
    let username: String
    let port: Int
    let hosts: [String]
    let hostKeys: [String]
    let serviceState: String
    let detail: String?
    let hostFingerprint: String?
    let enrolled: Bool
    let enrolledKey: String?
    var fingerprint: String {
        let parts = hostKeys.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "Unavailable" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// One SSH attachment to a stable tmux session. tmux, not Tron or the Gateway,
/// owns the remote shell across backgrounding and network loss.
@MainActor
@Observable
final class MacTerminalController {
    enum Stage: Equatable { case loading, setup(SetupNotice), preparing, trust(MacTerminalStatus), enrolling, terminal, failed(String) }
    enum SetupNotice: Equatable {
        case ready(username: String), needsGateway, macNotOnTailnet, serviceIssue(String), unpaired
    }
    var isChangingAuthorization: Bool { if case .enrolling = stage { return true }; return false }
    enum Link: Equatable { case idle, connecting, connected }

    private(set) var stage: Stage = .loading
    private(set) var link: Link = .idle
    private(set) var enrollment: MacTerminalEnrollment?
    private(set) var chunks: [TerminalChunk] = []
    private(set) var rendererGeneration = 0
    var isRunning: Bool { link == .connected }
    var phase: TerminalConnectionPhase {
        switch stage {
        case .loading, .preparing, .enrolling: .connecting
        case .setup, .trust: .notConnected
        case .failed: .unavailable
        case .terminal:
            switch link {
            case .idle: .notConnected
            case .connecting: .connecting
            case .connected: .connected
            }
        }
    }

    private let store: MacTerminalEnrollmentStore
    private var machineID: String?
    private var isPresented = false
    private var session: MacTerminalSession?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var generation = 0
    private var size = (columns: 80, rows: 24)
    private var localSequence = 0
    private var retainedBytes = 0
    private var pendingUTF8: [UInt8] = []
    private static let retainedByteLimit = 1 << 20

    init(store: MacTerminalEnrollmentStore = MacTerminalEnrollmentStore()) { self.store = store }

    func present(model: AppModel) {
        isPresented = true
        // An accepted key mutation owns its completion even across presentation/profile changes.
        guard !isChangingAuthorization else { return }
        guard let profile = model.profiles.selected else { reset(); stage = .setup(.unpaired); return }
        if machineID != profile.machineId { reset(); machineID = profile.machineId }
        if case .preparing = stage { return }
        if case .trust = stage { return }
        do {
            if let enrollment = try store.enrollment(machineID: profile.machineId) {
                self.enrollment = enrollment
                if enrollment.endpoint.port < 1024 {
                    // Keep the old record and identity intact; never dial stock SSH or silently repin.
                    Task { await refreshSetup(model: model) }
                    return
                }
                stage = .terminal
                connect()
            } else if stage == .loading {
                Task { await refreshSetup(model: model) }
            }
        } catch {
            stage = .failed("Mac Terminal enrollment could not be read safely. \(error.localizedDescription)")
        }
    }

    /// iOS can discard sockets while suspended. Detach explicitly; never replay input.
    func conceal() {
        isPresented = false
        closeLink()
        if case .preparing = stage { stage = .loading }
        if case .trust = stage { stage = .loading }
    }

    /// Re-reads the Mac's status for the setup notice ("Check Again").
    func refreshSetup(model: AppModel) async {
        guard !isChangingAuthorization else { return }
        closeLink()
        let accepted = generation
        guard let profile = model.profiles.selected else { stage = .setup(.unpaired); return }
        guard profile.deviceId != nil else { stage = .setup(.unpaired); return }
        guard model.connectionState == .connected else { stage = .setup(.needsGateway); return }
        stage = .loading
        do {
            let status = try await model.macTerminalStatus()
            guard accepted == generation, model.profiles.selected?.machineId == profile.machineId,
                  case .loading = stage else { return }
            stage = .setup(Self.notice(for: status))
        } catch {
            guard accepted == generation, case .loading = stage else { return }
            stage = .failed(error.localizedDescription)
        }
    }

    /// Explicit enable prepares the private service and identity only. It does
    /// not create a client key, publish authorization, or replace an old pin.
    func enroll(model: AppModel) async {
        guard !isChangingAuthorization,
              let profile = model.profiles.selected, profile.deviceId != nil else { return }
        closeLink()
        let accepted = generation
        stage = .preparing
        do {
            try await model.changeSetting(target: .object(["kind": .string("global")]), change: .object([
                "key": .string("permissions.macTerminalServer"), "layer": .string("global"),
                "op": .string("set"), "value": .bool(true),
            ]))
            guard accepted == generation, model.profiles.selected?.machineId == profile.machineId else {
                if accepted == generation { stage = .loading; if isPresented { present(model: model) } }
                return
            }
            let status = try await model.macTerminalStatus()
            guard accepted == generation, model.profiles.selected?.machineId == profile.machineId else {
                if accepted == generation { stage = .loading; if isPresented { present(model: model) } }
                return
            }
            guard status.serviceState == "running", status.hostKeys.count == 1 else {
                stage = .setup(Self.notice(for: status)); return
            }
            stage = .trust(status)
        } catch {
            guard accepted == generation else { return }
            stage = .failed(error.localizedDescription)
        }
    }

    func declineHost() {
        guard case .trust = stage else { return }
        closeLink()
        stage = .setup(.ready(username: enrollment?.endpoint.username ?? "your Mac account"))
    }

    func trustHost(model: AppModel) async {
        guard case .trust(let trusted) = stage,
              let profile = model.profiles.selected, let deviceID = profile.deviceId,
              profile.machineId == machineID else { return }
        let accepted = generation
        stage = .enrolling
        do {
            let status = try await model.macTerminalStatus()
            guard accepted == generation, model.profiles.selected?.machineId == profile.machineId,
                  model.profiles.selected?.deviceId == deviceID else {
                stage = .loading
                if isPresented { present(model: model) }
                return
            }
            guard status.serviceState == "running", status.hostKeys == trusted.hostKeys,
                  status.hosts == trusted.hosts, status.port == trusted.port, status.username == trusted.username else {
                stage = .failed("The private SSH endpoint changed before authorization. Check again and explicitly trust its fingerprint.")
                return
            }
            let key = try store.key(machineID: profile.machineId)
            try await model.setMacTerminalKey(device: deviceID, publicKey: key.openSSHPublicKey)
            // Accepted authorization owns this save even if the sheet closed.
            let record = MacTerminalEnrollment(machineID: profile.machineId, deviceID: deviceID,
                endpoint: MacTerminalEndpoint(hosts: status.hosts, port: status.port, username: status.username, hostKeys: status.hostKeys),
                publicKey: key.openSSHPublicKey, enrolledAt: Date())
            try store.save(record)
            if model.profiles.selected?.machineId != profile.machineId {
                reset()
                if isPresented { present(model: model) }
                return
            }
            enrollment = record
            machineID = profile.machineId
            stage = .terminal
            connect()
        } catch {
            if model.profiles.selected?.machineId != profile.machineId {
                reset()
                if isPresented { present(model: model) }
            } else { stage = .failed(error.localizedDescription) }
        }
    }

    /// Revokes this iPhone's key on the Mac, then forgets it here. The Mac
    /// change needs the Gateway; without it nothing local is removed, so the
    /// key cannot be orphaned on the Mac. Shells already open on the Mac keep
    /// running until they exit.
    func removeKey(model: AppModel) async throws {
        guard !isChangingAuthorization, let enrollment else { return }
        guard model.connectionState == .connected else {
            throw MacTerminalRemovalError.needsGateway
        }
        closeLink()
        stage = .enrolling
        do {
            try await model.setMacTerminalKey(device: enrollment.deviceID, publicKey: nil)
            try store.remove(machineID: enrollment.machineID)
            reset()
            if isPresented { present(model: model) }
        } catch {
            // A failed accepted mutation still belongs to the original Mac;
            // never reconnect its cached enrollment under a new selection.
            if model.profiles.selected?.machineId != enrollment.machineID {
                reset()
                if isPresented { present(model: model) }
            } else {
                stage = .terminal
                if isPresented { connect() }
            }
            throw error
        }
    }


    func reconnect() {
        closeLink()
        stage = .terminal
        connect()
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard isRunning else { return }
        session?.write(Array(bytes))
    }

    func resize(columns: Int, rows: Int) {
        size = (columns, rows)
        session?.resize(columns: columns, rows: rows)
    }

    private func reset() {
        closeLink()
        enrollment = nil
        machineID = nil
        replaceOutput()
        stage = .loading
    }

    private func closeLink() {
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        session?.close()
        session = nil
        link = .idle
    }

    private func connect() {
        guard isPresented, let enrollment, link == .idle else { return }
        guard macTerminalHasTailnetAddress() else {
            stage = .failed(MacTerminalError.notOnTailnet.localizedDescription)
            return
        }
        generation &+= 1
        let accepted = generation
        let size = size
        link = .connecting
        // Stable per Mac/iPhone; only a shell-safe digest crosses the SSH exec boundary.
        let digest = SHA256.hash(data: Data("\(enrollment.machineID):\(enrollment.deviceID)".utf8))
        let name = "tron-" + digest.map { String(format: "%02x", $0) }.joined()
        connectTask = Task { [weak self, store] in
            do {
                guard let key = try store.existingKey(machineID: enrollment.machineID) else {
                    throw MacTerminalRemovalError.keyMissing
                }
                let connected = try await MacTerminalClient.connect(
                    endpoint: enrollment.endpoint, privateKey: key, sessionName: name,
                    columns: size.columns, rows: size.rows)
                guard let self, accepted == self.generation, !Task.isCancelled else {
                    connected.close()
                    return
                }
                self.session = connected
                self.link = .connected
                self.stage = .terminal
                // tmux repaints its authoritative screen on every attachment;
                // feeding old transport output would corrupt that repaint.
                self.replaceOutput()
                self.eventTask = Task { [weak self] in
                    for await event in connected.events {
                        guard let self, accepted == self.generation else { return }
                        switch event {
                        case .output(let bytes): self.appendBytes(bytes)
                        case .diagnostic: break
                        case .closed: break
                        }
                    }
                    guard let self, accepted == self.generation else { return }
                    self.session = nil
                    self.link = .idle
                    self.appendNote("Disconnected. Reconnect to reattach to your tmux session.")
                }
            } catch {
                guard let self, accepted == self.generation, !Task.isCancelled else { return }
                self.link = .idle
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func replaceOutput() {
        chunks = []
        retainedBytes = 0
        pendingUTF8 = []
        rendererGeneration &+= 1
    }

    private func appendNote(_ text: String) {
        appendText("\r\n\u{1B}[2m[\(text)]\u{1B}[0m\r\n")
    }

    private func appendBytes(_ bytes: [UInt8]) {
        pendingUTF8 += bytes
        var end = pendingUTF8.count
        var back = 0
        while back < 3, end - back - 1 >= 0 {
            let byte = pendingUTF8[end - back - 1]
            if byte & 0xC0 != 0x80 {
                let width = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if width > back + 1 { end -= back + 1 }
                break
            }
            back += 1
        }
        guard end > 0 else { return }
        let text = String(decoding: pendingUTF8[..<end], as: UTF8.self)
        pendingUTF8.removeFirst(end)
        appendText(text)
    }

    private func appendText(_ text: String) {
        localSequence += 1
        chunks.append(TerminalChunk(sequence: localSequence, data: text))
        // Counted as retained text, the same measure removal subtracts.
        retainedBytes += text.utf8.count
        while retainedBytes > Self.retainedByteLimit, chunks.count > 1 {
            retainedBytes -= chunks.removeFirst().data.utf8.count
        }
    }


    private static func notice(for status: MacTerminalStatus) -> SetupNotice {
        if status.hosts.isEmpty { return .macNotOnTailnet }
        if status.serviceState == "unavailable" { return .macNotOnTailnet }
        if status.serviceState == "stale" || status.serviceState == "failed" {
            return .serviceIssue(status.detail ?? "Recover the private SSH service on the Mac, then explicitly refresh enrollment.")
        }
        if status.serviceState == "running" && status.hostKeys.count != 1 {
            return .serviceIssue("The private service has no verified host identity. Restore its identity on the Mac; Tron never rotates or repins it automatically.")
        }
        return .ready(username: status.username)
    }
}

enum MacTerminalRemovalError: LocalizedError {
    case needsGateway
    case keyMissing

    var errorDescription: String? {
        switch self {
        case .needsGateway:
            "Removing this iPhone's key changes the Mac, so it needs the Gateway. Connect to your Mac and try again, or revoke this iPhone in the private Mac Terminal service on the Mac."
        case .keyMissing:
            "This iPhone's Mac Terminal key is missing. Remove Mac Terminal and enable it again while the Gateway is running."
        }
    }
}

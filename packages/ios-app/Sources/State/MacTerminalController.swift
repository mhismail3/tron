import Foundation
import MacTerminalSSH
import Observation
import TronMobileCore

/// What `macTerminal.status` reports for this iPhone (Gateway
/// `security/mac-terminal.ts`).
struct MacTerminalStatus: Decodable, Equatable, Sendable {
    let username: String
    let port: Int
    let hosts: [String]
    let hostKeys: [String]
    let remoteLogin: String
    let enrolled: Bool
    let enrolledKey: String?
}

/// One Mac Terminal sheet's shell: enrollment while the Gateway is up, then a
/// direct SSH login shell that never touches the Gateway. The sheet's
/// presentation owns one controller; dismissing the sheet closes the
/// connection (the login shell gets SIGHUP, as when a Terminal window closes).
@MainActor
@Observable
final class MacTerminalController {
    enum Stage: Equatable {
        /// Reading this iPhone's enrollment and, when it has none, the Mac's status.
        case loading
        /// Not enrolled; the notice says what enabling needs.
        case setup(SetupNotice)
        case enrolling
        case connecting
        case connected
        /// The shell ended or the connection dropped; its output stays visible.
        case ended(String)
        /// No shell was opened; the text is the actionable cause.
        case failed(String)
    }

    enum SetupNotice: Equatable {
        case ready(username: String)
        case remoteLoginOff
        case needsGateway
        case macNotOnTailnet
        case noHostKeys
        case unpaired
    }

    private(set) var stage: Stage = .loading
    private(set) var chunks: [TerminalChunk] = []
    /// Advances per connection; output from an earlier shell is dropped.
    private(set) var connectionGeneration = 0
    /// Advances only when the output is discarded (the key is removed), so
    /// the sheet keeps one emulator across reconnects.
    private(set) var outputGeneration = 0
    private var started = false
    private(set) var enrollment: MacTerminalEnrollment?

    var isRunning: Bool { stage == .connected }

    var phase: TerminalConnectionPhase {
        switch stage {
        case .loading, .enrolling, .connecting: .connecting
        case .connected: .connected
        case .setup, .ended: .notConnected
        case .failed: .unavailable
        }
    }

    private let store: MacTerminalEnrollmentStore
    private var machineID: String?
    private var session: MacTerminalSession?
    private var sessionTask: Task<Void, Never>?
    private var size = (columns: 80, rows: 24)
    private var sequence = 0
    private var retainedBytes = 0
    private var pendingUTF8: [UInt8] = []
    /// The bound on retained output, oldest chunks first out. The emulator
    /// already holds the live screen; this only feeds a re-created view.
    private static let retainedByteLimit = 1 << 20

    init(store: MacTerminalEnrollmentStore = MacTerminalEnrollmentStore()) {
        self.store = store
    }

    /// Opens the shell for the selected Mac, or says what enabling it needs.
    func start(model: AppModel) {
        // A rebuilt sheet calls this again; its shell is already open.
        guard !started else { return }
        started = true
        guard let profile = model.profiles.selected else {
            stage = .setup(.unpaired)
            return
        }
        machineID = profile.machineId
        if let enrollment = store.enrollment(machineID: profile.machineId) {
            self.enrollment = enrollment
            open(enrollment)
        } else {
            Task { await refreshSetup(model: model) }
        }
    }

    /// Re-reads the Mac's status for the setup notice ("Check Again").
    func refreshSetup(model: AppModel) async {
        guard let profile = model.profiles.selected else { stage = .setup(.unpaired); return }
        guard profile.deviceId != nil else { stage = .setup(.unpaired); return }
        guard model.connectionState == .connected else { stage = .setup(.needsGateway); return }
        stage = .loading
        do {
            let status = try await model.macTerminalStatus()
            guard case .loading = stage else { return }
            stage = .setup(Self.notice(for: status))
        } catch {
            guard case .loading = stage else { return }
            stage = .failed(Self.describe(error))
        }
    }

    /// The maintainer's tap: creates this iPhone's key, writes it to the Mac's
    /// authorized_keys through the logged settings path, pins the host keys,
    /// and opens the first shell.
    func enroll(model: AppModel) async {
        guard let profile = model.profiles.selected, let deviceID = profile.deviceId else {
            stage = .setup(.unpaired)
            return
        }
        stage = .enrolling
        do {
            let status = try await model.macTerminalStatus()
            let notice = Self.notice(for: status)
            guard case .ready = notice else { stage = .setup(notice); return }
            let key = try store.key(machineID: profile.machineId)
            try await model.setMacTerminalKey(device: deviceID, publicKey: key.openSSHPublicKey)
            let enrollment = MacTerminalEnrollment(
                machineID: profile.machineId, deviceID: deviceID,
                endpoint: MacTerminalEndpoint(hosts: status.hosts, port: status.port,
                                              username: status.username, hostKeys: status.hostKeys),
                publicKey: key.openSSHPublicKey, enrolledAt: Date()
            )
            store.save(enrollment)
            self.enrollment = enrollment
            open(enrollment)
        } catch {
            stage = .failed(Self.describe(error))
        }
    }

    /// An older Gateway has no `macTerminal.status`: say what to do, not
    /// "Unknown gateway method".
    private static func describe(_ error: Error) -> String {
        if let failure = error as? GatewayFailure, failure.code == "not_found",
           failure.message.contains("macTerminal") {
            return "This Mac's Tron does not support Mac Terminal yet. Update Tron on the Mac, then try again."
        }
        return error.localizedDescription
    }

    /// Revokes this iPhone's key on the Mac, then forgets it here. The Mac
    /// change needs the Gateway; without it nothing local is removed, so the
    /// key cannot be orphaned on the Mac.
    func removeKey(model: AppModel) async throws {
        guard let enrollment else { return }
        guard model.connectionState == .connected else {
            throw MacTerminalRemovalError.needsGateway
        }
        try await model.setMacTerminalKey(device: enrollment.deviceID, publicKey: nil)
        try store.remove(machineID: enrollment.machineID)
        close()
        self.enrollment = nil
        chunks = []
        sequence = 0
        retainedBytes = 0
        outputGeneration &+= 1
        await refreshSetup(model: model)
    }

    func reconnect() {
        guard let enrollment else { return }
        open(enrollment)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard stage == .connected else { return }
        session?.write(Array(bytes))
    }

    func resize(columns: Int, rows: Int) {
        size = (columns, rows)
        session?.resize(columns: columns, rows: rows)
    }

    /// Ends the connection and its shell; the sheet calls this on dismissal.
    func close() {
        sessionTask?.cancel()
        sessionTask = nil
        session?.close()
        session = nil
    }

    private func open(_ enrollment: MacTerminalEnrollment) {
        close()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        // The earlier shell's output stays on screen; the new shell starts on
        // a fresh line with default attributes and the main screen.
        pendingUTF8 = []
        if !chunks.isEmpty {
            append(Array("\u{1B}[0m\u{1B}[?1049l\r\n".utf8), generation: generation)
        }
        stage = .connecting
        // The Gateway is not consulted from here on: a missing tailnet is
        // named before any dial would only time out.
        guard macTerminalHasTailnetAddress() else {
            stage = .failed(MacTerminalError.notOnTailnet.localizedDescription)
            return
        }
        let size = size
        sessionTask = Task { [weak self, store] in
            do {
                guard let key = try store.existingKey(machineID: enrollment.machineID) else {
                    throw MacTerminalRemovalError.keyMissing
                }
                let session = try await MacTerminalClient.connect(
                    endpoint: enrollment.endpoint, privateKey: key, columns: size.columns, rows: size.rows)
                guard let self, self.connectionGeneration == generation, !Task.isCancelled else {
                    session.close()
                    return
                }
                self.session = session
                self.stage = .connected
                var exit: Int?
                for await event in session.events {
                    switch event {
                    case .output(let bytes): self.append(bytes, generation: generation)
                    case .closed(let status): exit = status
                    }
                }
                guard self.connectionGeneration == generation, !Task.isCancelled else { return }
                self.session = nil
                let reason = exit.map { "The shell exited with status \($0)." } ?? "The connection to the Mac closed."
                self.stage = .ended(reason)
                // Said in the terminal itself, as a shell says it: the output
                // stays readable and ⋯ › Reconnect opens a new shell.
                self.append(Array("\r\n\u{1B}[2m[\(reason) Reconnect from the ⋯ menu.]\u{1B}[0m\r\n".utf8), generation: generation)
            } catch {
                guard let self, self.connectionGeneration == generation, !Task.isCancelled else { return }
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Output arrives in arbitrary byte splits; only whole UTF-8 sequences
    /// become text, so a character split across two packets is not mangled.
    private func append(_ bytes: [UInt8], generation: Int) {
        guard generation == connectionGeneration else { return }
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
        sequence += 1
        chunks.append(TerminalChunk(sequence: sequence, data: text))
        // Counted as retained text, the same measure removal subtracts.
        retainedBytes += text.utf8.count
        while retainedBytes > Self.retainedByteLimit, chunks.count > 1 {
            retainedBytes -= chunks.removeFirst().data.utf8.count
        }
    }

    private static func notice(for status: MacTerminalStatus) -> SetupNotice {
        if status.hosts.isEmpty { return .macNotOnTailnet }
        if status.remoteLogin == "off" { return .remoteLoginOff }
        // Nothing to pin means nothing to verify: never enroll without it.
        if status.hostKeys.isEmpty { return .noHostKeys }
        return .ready(username: status.username)
    }
}

enum MacTerminalRemovalError: LocalizedError {
    case needsGateway
    case keyMissing

    var errorDescription: String? {
        switch self {
        case .needsGateway:
            "Removing this iPhone's key changes the Mac, so it needs the Gateway. Connect to your Mac and try again, or delete the line marked tron-mac-terminal in ~/.ssh/authorized_keys on the Mac."
        case .keyMissing:
            "This iPhone's Mac Terminal key is missing. Remove Mac Terminal and enable it again while the Gateway is running."
        }
    }
}

extension MacTerminalController: PresentationScopedResource {
    func presentationDidRetire() { close() }
}

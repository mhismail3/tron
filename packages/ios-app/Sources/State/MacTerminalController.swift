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
    /// The argv that reaches the Mac's shell host; absent on an older Tron.
    let hostCommand: [String]?
}

/// Mac Terminal's shells (#1075). The shells live on the Mac, in the shell host
/// (Gateway `machine/mac-terminal-host.ts`), reached over SSH without the
/// Gateway; this app-scoped controller is the iPhone's view of them. Closing
/// the sheet or leaving the app only closes the SSH link, which detaches: the
/// shell, its programs and its output stay on the Mac until the user exits or
/// quits it (or the #479 idle policy closes it), and reopening reattaches and
/// replays what was missed.
///
/// A Mac whose Tron has no shell host gets a plain SSH login shell instead,
/// kept while the app holds its connection (not across the app being suspended).
@MainActor
@Observable
final class MacTerminalController {
    enum Stage: Equatable {
        /// Reading this iPhone's enrollment and, when it has none, the Mac's status.
        case loading
        /// Not enrolled; the notice says what enabling needs.
        case setup(SetupNotice)
        case enrolling
        /// Enrolled: the terminal (or "Connecting…" before its first output).
        case terminal
        /// Nothing could be shown; the text is the actionable cause.
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

    /// How the iPhone reaches the shells.
    enum Mode: Equatable {
        /// The Mac's shell host: shells persist and several can be open.
        case host
        /// One plain SSH login shell; the text says why there is no host.
        case plain(String)
    }

    enum Link: Equatable { case idle, connecting, connected }

    private(set) var stage: Stage = .loading
    private(set) var mode: Mode = .host
    private(set) var link: Link = .idle
    private(set) var enrollment: MacTerminalEnrollment?
    /// The host's shells, live and exited, in the order they were opened.
    private(set) var shells: [MacShell] = []
    private(set) var selectedShellID: String?
    /// The selected shell's output, a bounded projection of the host's replay.
    private(set) var chunks: [TerminalChunk] = []
    /// Advances whenever `chunks` is replaced rather than extended, so the
    /// sheet gives the replaced output a fresh emulator.
    private(set) var rendererGeneration = 0
    /// The plain shell has ended.
    private(set) var plainEnded = false

    var selectedShell: MacShell? { shells.first { $0.id == selectedShellID } }
    var liveShells: [MacShell] { shells.filter { !$0.hasExited } }
    var exitedShells: [MacShell] { shells.filter(\.hasExited) }

    var isRunning: Bool {
        guard link == .connected else { return false }
        switch mode {
        case .host: return selectedShell.map { !$0.hasExited } ?? false
        case .plain: return !plainEnded
        }
    }

    var phase: TerminalConnectionPhase {
        switch stage {
        case .loading, .enrolling: .connecting
        case .setup: .notConnected
        case .failed: .unavailable
        case .terminal:
            switch link {
            case .connecting: .connecting
            case .connected: isRunning ? .connected : .notConnected
            case .idle: .notConnected
            }
        }
    }

    private let store: MacTerminalEnrollmentStore
    private var machineID: String?
    private var isPresented = false
    private var hostLink: MacTerminalHostLink?
    private var plainSession: MacTerminalSession?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// Advances per link, so a retired link's late events and results are dropped.
    private var linkGeneration = 0
    private var size = (columns: 80, rows: 24)
    /// The last host sequence installed for the selected shell; `attach` resumes after it.
    private var hostSequence = 0
    /// Output that arrived for the selected shell while its attach was in flight.
    private var attaching = false
    private var heldOutput: [MacShellChunk] = []
    /// The renderer's own sequence: host chunks and local notes share it.
    private var localSequence = 0
    private var retainedBytes = 0
    private var pendingUTF8: [UInt8] = []
    /// The bound on retained output, oldest chunks first out. The host keeps
    /// the authoritative replay; this only feeds a re-created view.
    private static let retainedByteLimit = 1 << 20

    init(store: MacTerminalEnrollmentStore = MacTerminalEnrollmentStore()) {
        self.store = store
    }

    // MARK: - Presentation

    /// The sheet appeared, or the app came back while it is open: show what is
    /// retained at once and (re)attach to the selected shell.
    func present(model: AppModel) {
        isPresented = true
        guard let profile = model.profiles.selected else {
            reset()
            stage = .setup(.unpaired)
            return
        }
        if machineID != profile.machineId {
            reset()
            machineID = profile.machineId
        }
        if let enrollment = enrollment ?? store.enrollment(machineID: profile.machineId) {
            self.enrollment = enrollment
            stage = .terminal
            refreshHostCommand(model: model)
            connect()
        } else {
            Task { await refreshSetup(model: model) }
        }
    }

    /// The sheet closed or the app left the foreground. Only the link closes:
    /// the host keeps the shell. A plain shell stays while iOS keeps its socket.
    func conceal() {
        isPresented = false
        guard mode == .host else { return }
        closeLink()
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
                endpoint: MacTerminalEndpoint(hosts: status.hosts, port: status.port, username: status.username,
                                              hostKeys: status.hostKeys, hostCommand: status.hostCommand),
                publicKey: key.openSSHPublicKey, enrolledAt: Date()
            )
            store.save(enrollment)
            machineID = profile.machineId
            self.enrollment = enrollment
            stage = .terminal
            connect()
        } catch {
            stage = .failed(Self.describe(error))
        }
    }

    /// The Mac's Tron moves its shell host with each install: while the Gateway
    /// answers, keep the cached command current. Host keys are never replaced here.
    private func refreshHostCommand(model: AppModel) {
        guard model.connectionState == .connected, let machineID else { return }
        Task {
            guard let status = try? await model.macTerminalStatus(),
                  let current = enrollment, current.machineID == machineID,
                  current.endpoint.hostCommand != status.hostCommand else { return }
            var endpoint = current.endpoint
            endpoint.hostCommand = status.hostCommand
            let updated = MacTerminalEnrollment(machineID: current.machineID, deviceID: current.deviceID, endpoint: endpoint,
                                                publicKey: current.publicKey, enrolledAt: current.enrolledAt)
            store.save(updated)
            enrollment = updated
            // A Mac that just gained its host replaces an ended plain shell.
            if case .plain = mode, plainEnded || plainSession == nil, isPresented, status.hostCommand != nil {
                mode = .host
                closeLink()
                connect()
            }
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
    /// key cannot be orphaned on the Mac. Shells already open on the Mac keep
    /// running until they exit or the idle policy closes them.
    func removeKey(model: AppModel) async throws {
        guard let enrollment else { return }
        guard model.connectionState == .connected else {
            throw MacTerminalRemovalError.needsGateway
        }
        try await model.setMacTerminalKey(device: enrollment.deviceID, publicKey: nil)
        try store.remove(machineID: enrollment.machineID)
        reset()
        machineID = enrollment.machineID
        await refreshSetup(model: model)
    }

    // MARK: - Shell actions

    /// ⋯ › Reconnect / Try Again: a fresh link to the same selected shell.
    func reconnect() {
        closeLink()
        stage = .terminal
        connect()
    }

    /// ⋯ › New Shell.
    func newShell() {
        switch mode {
        case .plain:
            closeLink()
            connect()
        case .host:
            guard let hostLink, link == .connected else {
                pendingNewShell = true
                connect()
                return
            }
            openShell(on: hostLink, generation: linkGeneration)
        }
    }

    /// ⋯ › a shell in Open or Recent shells.
    func select(_ shell: MacShell) {
        guard mode == .host, shell.id != selectedShellID else { return }
        if let hostLink, link == .connected {
            if let previous = selectedShellID { hostLink.detach(previous) }
            selectedShellID = shell.id
            replaceOutput()
            attach(shell.id, on: hostLink, generation: linkGeneration)
        } else {
            selectedShellID = shell.id
            replaceOutput()
            connect()
        }
    }

    /// ⋯ › Quit Shell: ends the selected shell and its process group.
    func quit() {
        switch mode {
        case .plain:
            plainSession?.close()
        case .host:
            guard let hostLink, let shell = selectedShellID else { return }
            let generation = linkGeneration
            Task {
                do {
                    try await hostLink.terminate(shell)
                } catch {
                    guard generation == linkGeneration else { return }
                    appendNote("Could not quit the shell: \(error.localizedDescription)")
                }
            }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard isRunning else { return }
        switch mode {
        case .plain:
            plainSession?.write(Array(bytes))
        case .host:
            guard let shell = selectedShellID else { return }
            hostLink?.write(shell, String(decoding: bytes, as: UTF8.self))
        }
    }

    func resize(columns: Int, rows: Int) {
        size = (columns, rows)
        switch mode {
        case .plain: plainSession?.resize(columns: columns, rows: rows)
        case .host:
            if let shell = selectedShellID { hostLink?.resize(shell, columns: columns, rows: rows) }
        }
    }

    // MARK: - Link

    private var pendingNewShell = false

    private func reset() {
        closeLink()
        enrollment = nil
        machineID = nil
        mode = .host
        shells = []
        selectedShellID = nil
        replaceOutput()
        stage = .loading
    }

    private func closeLink() {
        linkGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        if let hostLink {
            if let shell = selectedShellID { hostLink.detach(shell) }
            hostLink.close()
        }
        hostLink = nil
        plainSession?.close()
        plainSession = nil
        attaching = false
        heldOutput = []
        link = .idle
    }

    private func connect() {
        guard isPresented, let enrollment, link == .idle else { return }
        // The Gateway is not consulted from here on: a missing tailnet is
        // named before any dial would only time out.
        guard macTerminalHasTailnetAddress() else {
            let message = MacTerminalError.notOnTailnet.localizedDescription
            if chunks.isEmpty { stage = .failed(message) } else { appendNote(message) }
            return
        }
        linkGeneration &+= 1
        let generation = linkGeneration
        link = .connecting
        let size = size
        let store = store
        // Every connection tries the shell host first when the Mac has one.
        let plainReason: String? = enrollment.endpoint.hostCommand == nil
            ? "This Mac's Tron cannot keep shells open yet; update Tron on the Mac." : nil
        connectTask = Task { [weak self] in
            do {
                guard let key = try store.existingKey(machineID: enrollment.machineID) else {
                    throw MacTerminalRemovalError.keyMissing
                }
                if let reason = plainReason {
                    let session = try await MacTerminalClient.connect(
                        endpoint: enrollment.endpoint, privateKey: key, columns: size.columns, rows: size.rows)
                    self?.installPlain(session, reason: reason, generation: generation)
                    return
                }
                do {
                    let hostLink = try await MacTerminalHostLink.open(
                        endpoint: enrollment.endpoint, privateKey: key, command: enrollment.endpoint.hostCommand ?? [])
                    self?.installHost(hostLink, generation: generation)
                } catch let error as MacTerminalHostError {
                    // The lifeline: without a shell host the Mac still gets a shell.
                    let session = try await MacTerminalClient.connect(
                        endpoint: enrollment.endpoint, privateKey: key, columns: size.columns, rows: size.rows)
                    self?.installPlain(session, reason: error.localizedDescription, generation: generation)
                }
            } catch {
                guard let self, generation == self.linkGeneration, !Task.isCancelled else { return }
                self.link = .idle
                if self.chunks.isEmpty {
                    self.stage = .failed(error.localizedDescription)
                } else {
                    self.appendNote("Could not reach the Mac: \(error.localizedDescription) Reconnect from the ⋯ menu.")
                }
            }
        }
    }

    private func installHost(_ hostLink: MacTerminalHostLink, generation: Int) {
        guard generation == linkGeneration, !Task.isCancelled else {
            hostLink.close()
            return
        }
        self.hostLink = hostLink
        mode = .host
        eventTask = Task { [weak self] in
            for await event in hostLink.events {
                guard let self, generation == self.linkGeneration else { return }
                self.handle(event)
            }
            guard let self, generation == self.linkGeneration else { return }
            // The link dropped (the app was suspended, the network moved):
            // the shell is still on the Mac.
            self.hostLink = nil
            self.link = .idle
            self.appendNote("Disconnected from the Mac; the shell is still running there. Reconnect from the ⋯ menu.")
        }
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listed = try await hostLink.list()
                guard generation == self.linkGeneration else { return }
                self.shells = listed
                let live = listed.filter { !$0.hasExited }
                if self.pendingNewShell || (self.selectedShell == nil && live.isEmpty) {
                    self.pendingNewShell = false
                    self.openShell(on: hostLink, generation: generation)
                } else {
                    let target = self.selectedShell ?? live.last!
                    if target.id != self.selectedShellID {
                        self.selectedShellID = target.id
                        self.replaceOutput()
                    }
                    self.attach(target.id, on: hostLink, generation: generation)
                }
            } catch {
                guard generation == self.linkGeneration else { return }
                self.failLink(error)
            }
        }
    }

    private func installPlain(_ session: MacTerminalSession, reason: String, generation: Int) {
        guard generation == linkGeneration, !Task.isCancelled else {
            session.close()
            return
        }
        plainSession = session
        mode = .plain(reason)
        shells = []
        selectedShellID = nil
        replaceOutput()
        plainEnded = false
        link = .connected
        stage = .terminal
        appendNote("\(reason) This shell ends when its connection does.")
        eventTask = Task { [weak self] in
            var exit: Int?
            for await event in session.events {
                guard let self, generation == self.linkGeneration else { return }
                switch event {
                case .output(let bytes): self.appendBytes(bytes)
                case .diagnostic: break
                case .closed(let status): exit = status
                }
            }
            guard let self, generation == self.linkGeneration else { return }
            self.plainSession = nil
            self.plainEnded = true
            self.link = .idle
            let reason = exit.map { "The shell exited with status \($0)." } ?? "The connection to the Mac closed."
            self.appendNote("\(reason) Open a new shell from the ⋯ menu.")
        }
    }

    private func openShell(on hostLink: MacTerminalHostLink, generation: Int) {
        if let previous = selectedShellID { hostLink.detach(previous) }
        attaching = true
        heldOutput = []
        let size = size
        Task { [weak self] in
            do {
                let replay = try await hostLink.openShell(columns: size.columns, rows: size.rows)
                guard let self, generation == self.linkGeneration else { return }
                self.shells.append(replay.shell)
                self.selectedShellID = replay.shell.id
                self.replaceOutput()
                self.install(replay)
            } catch {
                guard let self, generation == self.linkGeneration else { return }
                self.attaching = false
                self.failLink(error)
            }
        }
    }

    private func attach(_ shell: String, on hostLink: MacTerminalHostLink, generation: Int) {
        attaching = true
        heldOutput = []
        let after = hostSequence
        Task { [weak self] in
            do {
                let replay = try await hostLink.attach(shell, after: after)
                guard let self, generation == self.linkGeneration, self.selectedShellID == shell else { return }
                if replay.reset { self.replaceOutput() }
                self.install(replay)
                if !replay.shell.hasExited { hostLink.resize(shell, columns: self.size.columns, rows: self.size.rows) }
            } catch {
                guard let self, generation == self.linkGeneration else { return }
                self.attaching = false
                self.failLink(error)
            }
        }
    }

    /// Applies an attach/open replay, then the output that raced it.
    private func install(_ replay: MacShellReplay) {
        updateInventory(replay.shell)
        for chunk in replay.chunks where chunk.sequence > hostSequence { appendHost(chunk) }
        for chunk in heldOutput where chunk.sequence > hostSequence { appendHost(chunk) }
        heldOutput = []
        attaching = false
        link = .connected
        stage = .terminal
    }

    private func handle(_ event: MacShellEvent) {
        switch event {
        case .output(let shell, let chunk):
            guard shell == selectedShellID else { return }
            if attaching { heldOutput.append(chunk); return }
            if chunk.sequence > hostSequence { appendHost(chunk) }
        case .exited(let shell, let exitCode, let closedReason):
            if let index = shells.firstIndex(where: { $0.id == shell }) {
                let old = shells[index]
                shells[index] = MacShell(id: old.id, createdAt: old.createdAt, sequence: old.sequence,
                                         exitedAt: ISO8601DateFormatter().string(from: Date()), exitCode: exitCode,
                                         closedReason: closedReason)
            }
            guard shell == selectedShellID, closedReason == nil else { return }
            // An idle closure already ends the replay with its bracketed reason.
            appendNote("The shell exited\(exitCode.map { " with status \($0)" } ?? ""). Open a new shell from the ⋯ menu.")
        }
    }

    private func updateInventory(_ shell: MacShell) {
        if let index = shells.firstIndex(where: { $0.id == shell.id }) { shells[index] = shell } else { shells.append(shell) }
    }

    private func failLink(_ error: Error) {
        let message = error.localizedDescription
        closeLink()
        if chunks.isEmpty { stage = .failed(message) } else { appendNote("\(message) Reconnect from the ⋯ menu.") }
    }

    // MARK: - Output projection

    private func replaceOutput() {
        chunks = []
        hostSequence = 0
        retainedBytes = 0
        pendingUTF8 = []
        rendererGeneration &+= 1
    }

    private func appendHost(_ chunk: MacShellChunk) {
        hostSequence = chunk.sequence
        appendText(chunk.data)
    }

    /// Said in the terminal itself, dimmed, as a shell says it.
    private func appendNote(_ text: String) {
        appendText("\r\n\u{1B}[2m[\(text)]\u{1B}[0m\r\n")
    }

    /// A plain shell's output arrives in arbitrary byte splits; only whole
    /// UTF-8 sequences become text, so a character split across two packets is
    /// not mangled. (The host already sends whole characters.)
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

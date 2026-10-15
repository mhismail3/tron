import Foundation
import Synchronization

/// One shell the Mac's shell host holds (Gateway `machine/mac-terminal-host.ts`).
public struct MacShell: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let createdAt: String
    /// The last output sequence the host had when this summary was taken.
    public let sequence: Int
    public let exitedAt: String?
    public let exitCode: Int?
    /// Why the host closed it (#479 idle policy), in the words a client shows.
    public let closedReason: String?

    public var hasExited: Bool { exitedAt != nil }

    public init(id: String, createdAt: String, sequence: Int, exitedAt: String? = nil, exitCode: Int? = nil, closedReason: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.sequence = sequence
        self.exitedAt = exitedAt
        self.exitCode = exitCode
        self.closedReason = closedReason
    }
}

public struct MacShellChunk: Codable, Equatable, Sendable {
    public let sequence: Int
    public let data: String
}

/// A shell's retained output after `after`; `reset` means the host no longer
/// has everything after it, so the chunks replace what the client shows.
public struct MacShellReplay: Decodable, Equatable, Sendable {
    public let shell: MacShell
    public let chunks: [MacShellChunk]
    public let reset: Bool
}

public enum MacShellEvent: Sendable, Equatable {
    case output(shell: String, chunk: MacShellChunk)
    case exited(shell: String, exitCode: Int?, closedReason: String?)
}

public enum MacTerminalHostError: Error, Equatable, Sendable, LocalizedError {
    /// The Mac has no shell host to run (an older Tron, or a moved one); the
    /// text is what the command printed, if anything.
    case unavailable(String)
    /// The host refused a request.
    case refused(code: String, message: String)
    /// The link closed before the host answered.
    case closed

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "This Mac's Tron cannot keep shells open\(detail.isEmpty ? "" : " (\(detail))")."
        case .refused(_, let message): message
        case .closed: "The connection to the Mac closed."
        }
    }
}

/// Mac Terminal's link to the Mac's shell host: one SSH exec channel running
/// the host's `connect` relay, speaking one JSON object per line. Shells live
/// in the host, so closing this link (a dismissed sheet, a suspended app)
/// only detaches; `attach(after:)` later resumes from the last sequence seen.
public final class MacTerminalHostLink: Sendable {
    public let events: AsyncStream<MacShellEvent>
    /// Finishes once the link has closed, with the reason when there is one.
    public let closed: AsyncStream<String>

    private let session: MacTerminalSession
    private let state = Mutex(State())
    private let reader: Mutex<Task<Void, Never>?> = Mutex(nil)

    private struct State {
        var nextID = 0
        var pending: [Int: CheckedContinuation<Data, Error>] = [:]
        var isClosed = false
    }

    private init(session: MacTerminalSession, events: AsyncStream<MacShellEvent>, closed: AsyncStream<String>) {
        self.session = session
        self.events = events
        self.closed = closed
    }

    /// Dials the Mac, runs the host command and waits for the host's hello.
    /// SSH failures throw `MacTerminalError`; a Mac without a host throws
    /// `MacTerminalHostError.unavailable`.
    public static func open(
        endpoint: MacTerminalEndpoint,
        privateKey: MacTerminalPrivateKey,
        command: [String],
        helloTimeout: Duration = .seconds(12)
    ) async throws -> MacTerminalHostLink {
        let session = try await MacTerminalClient.exec(endpoint: endpoint, privateKey: privateKey,
                                                       command: shellQuoted(command))
        let (events, eventSink) = AsyncStream.makeStream(of: MacShellEvent.self, bufferingPolicy: .unbounded)
        let (closed, closedSink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let link = MacTerminalHostLink(session: session, events: events, closed: closed)
        let hello = AsyncStream.makeStream(of: Result<Void, MacTerminalHostError>.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var buffer: [UInt8] = []
            var stderr: [UInt8] = []
            var greeted = false
            var exitStatus: Int?
            for await event in session.events {
                switch event {
                case .output(let bytes):
                    buffer += bytes
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                            // A login rc file may print before the relay
                            // starts; only JSON lines are the protocol.
                            continue
                        }
                        if !greeted {
                            guard let greeting = object["hello"] as? [String: Any] else { continue }
                            greeted = true
                            // The host's socket carries its protocol version, so
                            // a different one is another Tron's host, never a
                            // partial match.
                            let version = greeting["protocol"] as? Int
                            hello.continuation.yield(version == 1 ? .success(())
                                : .failure(.unavailable("protocol \(version.map(String.init) ?? "unknown")")))
                            continue
                        }
                        link.route(object, events: eventSink)
                    }
                case .diagnostic(let bytes):
                    stderr = Array((stderr + bytes).suffix(2_048))
                case .closed(let status):
                    exitStatus = status
                }
            }
            let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !greeted {
                hello.continuation.yield(.failure(.unavailable(
                    detail.isEmpty ? exitStatus.map { "exit status \($0)" } ?? "" : String(detail.prefix(300)))))
            }
            link.failPending()
            eventSink.finish()
            closedSink.yield(detail)
            closedSink.finish()
            hello.continuation.finish()
        }
        link.reader.withLock { $0 = task }
        let timeout = Task {
            try await Task.sleep(for: helloTimeout)
            hello.continuation.yield(.failure(.unavailable("no answer")))
        }
        defer { timeout.cancel() }
        var iterator = hello.stream.makeAsyncIterator()
        switch await iterator.next() {
        case .success?:
            return link
        case .failure(let error)?:
            link.close()
            throw error
        case nil:
            link.close()
            throw MacTerminalHostError.closed
        }
    }

    public func list() async throws -> [MacShell] {
        struct Result: Decodable { let shells: [MacShell] }
        return try decode(Result.self, from: await request(["op": "list"])).shells
    }

    /// Opens a new login shell in the home directory and attaches to it.
    public func openShell(columns: Int, rows: Int) async throws -> MacShellReplay {
        try decode(MacShellReplay.self, from: await request(["op": "open", "columns": clamp(columns, 20, 500), "rows": clamp(rows, 5, 300)]))
    }

    /// Attaches to a shell, replaying what it printed after `after`.
    public func attach(_ shell: String, after: Int) async throws -> MacShellReplay {
        try decode(MacShellReplay.self, from: await request(["op": "attach", "shell": shell, "after": max(after, 0)]))
    }

    public func detach(_ shell: String) {
        post(["op": "detach", "shell": shell])
    }

    /// Input is ordered on the one SSH channel, so it is sent without waiting.
    public func write(_ shell: String, _ data: String) {
        guard !data.isEmpty else { return }
        post(["op": "write", "shell": shell, "data": data])
    }

    public func resize(_ shell: String, columns: Int, rows: Int) {
        post(["op": "resize", "shell": shell, "columns": clamp(columns, 20, 500), "rows": clamp(rows, 5, 300)])
    }

    /// Ends the shell and its process group (Quit), like `terminal.terminate`.
    public func terminate(_ shell: String) async throws {
        _ = try await request(["op": "terminate", "shell": shell])
    }

    /// Closes the link only; the host keeps every shell.
    public func close() {
        session.close()
    }

    // MARK: - Wire

    private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }

    private func post(_ frame: [String: Any]) {
        let id = state.withLock { state -> Int? in
            guard !state.isClosed else { return nil }
            state.nextID += 1
            return state.nextID
        }
        guard let id else { return }
        send(frame, id: id)
    }

    private func request(_ frame: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let id = state.withLock { state -> Int? in
                guard !state.isClosed else { return nil }
                state.nextID += 1
                state.pending[state.nextID] = continuation
                return state.nextID
            }
            guard let id else {
                continuation.resume(throwing: MacTerminalHostError.closed)
                return
            }
            send(frame, id: id)
        }
    }

    private func send(_ frame: [String: Any], id: Int) {
        var frame = frame
        frame["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        data.append(0x0A)
        session.write(Array(data))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    private func route(_ object: [String: Any], events: AsyncStream<MacShellEvent>.Continuation) {
        if let id = object["id"] as? Int {
            let continuation = state.withLock { $0.pending.removeValue(forKey: id) }
            guard let continuation else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: MacTerminalHostError.refused(
                    code: error["code"] as? String ?? "internal", message: error["message"] as? String ?? "The Mac refused the request."))
            } else {
                let result = object["result"] ?? [String: Any]()
                continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8))
            }
            return
        }
        guard let shell = object["shell"] as? String else { return }
        switch object["event"] as? String {
        case "output":
            guard let sequence = object["sequence"] as? Int, let data = object["data"] as? String else { return }
            events.yield(.output(shell: shell, chunk: MacShellChunk(sequence: sequence, data: data)))
        case "exit":
            events.yield(.exited(shell: shell, exitCode: object["exitCode"] as? Int, closedReason: object["closedReason"] as? String))
        default:
            return
        }
    }

    private func failPending() {
        let pending = state.withLock { state -> [CheckedContinuation<Data, Error>] in
            state.isClosed = true
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: MacTerminalHostError.closed) }
    }
}

/// sshd runs an exec request through the login user's shell (`$SHELL -c`), so
/// each argument is single-quoted.
func shellQuoted(_ arguments: [String]) -> String {
    arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
}

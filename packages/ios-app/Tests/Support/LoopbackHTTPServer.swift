import Foundation
import Network

/// A loopback HTTP/1.1 keep-alive server for transport tests that need real
/// TCP connections. It records which accepted connection carried each request
/// and answers from the test's handler, which may suspend to hold a response.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        /// One-based index of the accepted TCP connection that carried it.
        let connection: Int
        /// One-based position of this request on its connection.
        let sequenceOnConnection: Int
        let method: String
        let path: String
        /// Header values keyed by lowercased name.
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status = 200
        var headers: [(String, String)] = []
        var body = Data()
        /// Sends the body as one HTTP chunk without a declared length.
        var chunked = false
        /// Closes the connection instead of answering, like a keep-alive
        /// connection the server retired as the request arrived.
        var closesWithoutResponse = false
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let handler: Handler
    private let lock = NSLock()
    private var acceptedConnections = 0
    private var requests: [Request] = []
    private var connections: [NWConnection] = []

    let port: UInt16

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static func start(handler: @escaping Handler) async throws -> LoopbackHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LoopbackHTTPServer.ready")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let ready = ReadyOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { ready.finish(.success(port)) }
                    else { ready.finish(.failure(URLError(.cannotConnectToHost))) }
                case .failed(let error): ready.finish(.failure(error))
                case .cancelled: ready.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        return LoopbackHTTPServer(listener: listener, port: port, handler: handler)
    }

    private init(listener: NWListener, port: UInt16, handler: @escaping Handler) {
        self.listener = listener
        self.port = port
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func url(_ path: String) -> URL { baseURL.appending(path: path) }

    func connectionCount() -> Int { lock.withLock { acceptedConnections } }

    func recordedRequests() -> [Request] { lock.withLock { requests } }

    func waitUntilRequests(count: Int) async throws {
        while recordedRequests().count < count { try await Task.sleep(for: .milliseconds(5)) }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = lock.withLock { () -> Int in
            acceptedConnections += 1
            connections.append(connection)
            return acceptedConnections
        }
        connection.start(queue: queue)
        receive(on: connection, id: id, sequence: 1, buffer: Data())
    }

    private func receive(on connection: NWConnection, id: Int, sequence: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let (request, remainder) = Self.parse(buffer, connection: id, sequence: sequence) {
                lock.withLock { requests.append(request) }
                let handler = handler
                Task {
                    let response = await handler(request)
                    if response.closesWithoutResponse {
                        connection.cancel()
                        return
                    }
                    connection.send(content: Self.encode(response), completion: .contentProcessed { [weak self] error in
                        if error == nil { self?.receive(on: connection, id: id, sequence: sequence + 1, buffer: remainder) }
                    })
                }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(on: connection, id: id, sequence: sequence, buffer: buffer)
        }
    }

    private static func parse(_ buffer: Data, connection: Int, sequence: Int) -> (Request, Data)? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
        let request = Request(
            connection: connection,
            sequenceOnConnection: sequence,
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[end.upperBound..<bodyEnd])
        )
        return (request, Data(buffer[bodyEnd...]))
    }

    private static func encode(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        var body = response.body
        if response.chunked {
            head += "Transfer-Encoding: chunked\r\n"
            var chunked = Data(String(body.count, radix: 16).utf8 + Array("\r\n".utf8))
            chunked.append(body)
            chunked.append(Data("\r\n0\r\n\r\n".utf8))
            body = chunked
        } else if response.status != 204 && response.status != 304 {
            head += "Content-Length: \(body.count)\r\n"
        }
        var encoded = Data((head + "\r\n").utf8)
        encoded.append(body)
        return encoded
    }
}

private final class ReadyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }

    func finish(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<UInt16, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

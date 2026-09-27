import Foundation

struct BoundedHTTPDataTransport: Sendable {
    let dataForRequest: @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        precondition(maximumBytes >= 0)
        return try await dataForRequest(request, maximumBytes)
    }

    static let urlSession = BoundedHTTPDataTransport { request, maximumBytes in
        try await BoundedURLSessionDataLoader.load(request, maximumBytes: maximumBytes)
    }

    /// Credential-bearing capability requests never follow redirects.
    static let noRedirects = BoundedHTTPDataTransport { request, maximumBytes in
        try await BoundedURLSessionDataLoader.load(
            request,
            maximumBytes: maximumBytes,
            allowsRedirects: false
        )
    }
}

struct BoundedHTTPUploadTransport: Sendable {
    let dataForFileRequest: @Sendable (URLRequest, URL, Int) async throws -> (Data, HTTPURLResponse)

    func data(
        for request: URLRequest,
        fileURL: URL,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        precondition(maximumBytes >= 0)
        return try await dataForFileRequest(request, fileURL, maximumBytes)
    }

    static let urlSession = BoundedHTTPUploadTransport { request, fileURL, maximumBytes in
        try await BoundedURLSessionDataLoader.load(
            request,
            uploadFileURL: fileURL,
            maximumBytes: maximumBytes
        )
    }
}

struct BoundedHTTPBodyAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    mutating func admit(response: URLResponse) throws {
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= Int64(maximumBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        if expected > 0 {
            data.reserveCapacity(min(maximumBytes, Int(expected)))
        }
    }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= maximumBytes - data.count else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        data.append(chunk)
    }
}

/// Routes bounded requests between one long-lived shared session and a fresh
/// session per request. Idempotent bodiless reads share a session so their
/// keep-alive connections are reused (live-view frame polling would otherwise
/// open a TCP connection per frame); per-task delegates keep each request's
/// bounds, redirect policy and cancellation. Every other request keeps a fresh
/// session per request: a request that is unsafe to replay must not depend on
/// how CFNetwork recovers a reused connection the server already closed, which
/// can surface as `networkConnectionLost`.
enum BoundedHTTPReadSession {
    static func admits(_ request: URLRequest, uploadFileURL: URL? = nil) -> Bool {
        guard uploadFileURL == nil, request.httpBody == nil, request.httpBodyStream == nil else { return false }
        return request.httpMethod == "GET" || request.httpMethod == "HEAD"
    }

    /// A shared session with the request queueing behavior of a fresh session
    /// per request. CFNetwork otherwise queues requests beyond a small
    /// per-host connection count; this is its widest working value (larger
    /// values stop requests from starting).
    static func configured(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let shared = configuration.copy() as! URLSessionConfiguration
        shared.httpMaximumConnectionsPerHost = Int(Int32.max)
        return shared
    }
}

/// The sessions one bounded data transport configuration runs on.
struct BoundedHTTPDataSessions: Sendable {
    let freshConfiguration: @Sendable () -> URLSessionConfiguration
    let readSession: URLSession

    /// `configuration` returns a new configuration per call, so each fresh
    /// session has private cache, cookie and credential storage.
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        freshConfiguration = configuration
        let read = BoundedHTTPReadSession.configured(configuration())
        // A fresh session per request never carried a cached response, cookie
        // or credential into a later request; the shared session keeps none.
        read.urlCache = nil
        read.httpCookieStorage = nil
        read.urlCredentialStorage = nil
        readSession = URLSession(configuration: read)
    }

    static let ephemeral = BoundedHTTPDataSessions { .ephemeral }
}

final class BoundedURLSessionDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator: BoundedHTTPBodyAccumulator
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    /// The fresh session a non-read request owns; nil on the shared read session.
    private var ownedSession: URLSession?
    private var task: URLSessionDataTask?
    private var cancellationRequested = false
    private var terminalResult: Result<(Data, HTTPURLResponse), Error>?
    private let sessions: BoundedHTTPDataSessions
    private let allowsRedirects: Bool

    private init(
        maximumBytes: Int,
        sessions: BoundedHTTPDataSessions,
        allowsRedirects: Bool
    ) {
        accumulator = BoundedHTTPBodyAccumulator(maximumBytes: maximumBytes)
        self.sessions = sessions
        self.allowsRedirects = allowsRedirects
    }

    static func load(
        _ request: URLRequest,
        uploadFileURL: URL? = nil,
        maximumBytes: Int,
        sessions: BoundedHTTPDataSessions = .ephemeral,
        allowsRedirects: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let loader = BoundedURLSessionDataLoader(
            maximumBytes: maximumBytes,
            sessions: sessions,
            allowsRedirects: allowsRedirects
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(request, uploadFileURL: uploadFileURL, continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func start(
        _ request: URLRequest,
        uploadFileURL: URL?,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let task: URLSessionDataTask
        let ownedSession: URLSession?
        if BoundedHTTPReadSession.admits(request, uploadFileURL: uploadFileURL) {
            task = sessions.readSession.dataTask(with: request)
            task.delegate = self
            ownedSession = nil
        } else {
            let session = URLSession(configuration: sessions.freshConfiguration(), delegate: self, delegateQueue: nil)
            task = if let uploadFileURL {
                session.uploadTask(with: request, fromFile: uploadFileURL)
            } else {
                session.dataTask(with: request)
            }
            ownedSession = session
        }

        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            if let ownedSession { ownedSession.invalidateAndCancel() } else { task.cancel() }
            return
        }
        self.ownedSession = ownedSession
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        guard let task else {
            finish(.failure(CancellationError()))
            return
        }
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(allowsRedirects ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let admissionError: Error? = lock.withLock {
            do {
                try accumulator.admit(response: response)
                self.response = response
                return nil
            } catch {
                return error
            }
        }
        if let admissionError {
            completionHandler(.cancel)
            finish(.failure(admissionError))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let admissionError: Error? = lock.withLock {
            do {
                try accumulator.append(data)
                return nil
            } catch {
                return error
            }
        }
        if let admissionError {
            dataTask.cancel()
            finish(.failure(admissionError))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let cancellationRequested = self.cancellationRequested
        lock.unlock()
        if cancellationRequested {
            finish(.failure(CancellationError()))
            return
        }
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = accumulator.data
        lock.unlock()
        guard let response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        let ownedSession = self.ownedSession
        self.ownedSession = nil
        let task = self.task
        self.task = nil
        lock.unlock()

        if let ownedSession {
            ownedSession.invalidateAndCancel()
        } else if case .failure = result {
            // Retire only this request; the shared session and its other
            // requests continue.
            task?.cancel()
        }
        continuation?.resume(with: result)
    }
}

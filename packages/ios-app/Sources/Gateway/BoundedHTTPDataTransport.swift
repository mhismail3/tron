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

final class BoundedURLSessionDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator: BoundedHTTPBodyAccumulator
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancellationRequested = false
    private var terminalResult: Result<(Data, HTTPURLResponse), Error>?

    private init(maximumBytes: Int) {
        accumulator = BoundedHTTPBodyAccumulator(maximumBytes: maximumBytes)
    }

    static func load(
        _ request: URLRequest,
        uploadFileURL: URL? = nil,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let loader = BoundedURLSessionDataLoader(maximumBytes: maximumBytes)
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

        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task: URLSessionDataTask = if let uploadFileURL {
            session.uploadTask(with: request, fromFile: uploadFileURL)
        } else {
            session.dataTask(with: request)
        }

        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        self.session = session
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
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            lock.lock()
            defer { lock.unlock() }
            try accumulator.admit(response: response)
            self.response = response
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            lock.lock()
            defer { lock.unlock() }
            try accumulator.append(data)
        } catch {
            dataTask.cancel()
            finish(.failure(error))
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
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

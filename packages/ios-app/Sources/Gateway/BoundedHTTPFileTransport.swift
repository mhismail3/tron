import Foundation

struct BoundedHTTPDownloadedFile: Sendable {
    let url: URL
    let response: HTTPURLResponse
    let byteCount: Int64
}

struct BoundedHTTPFileTransport: Sendable {
    let downloadForRequest: @Sendable (URLRequest, Int) async throws -> BoundedHTTPDownloadedFile

    func download(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> BoundedHTTPDownloadedFile {
        precondition(maximumBytes >= 0)
        return try await downloadForRequest(request, maximumBytes)
    }

    static let urlSession = urlSession(configuration: .ephemeral)

    static func urlSession(configuration: URLSessionConfiguration) -> BoundedHTTPFileTransport {
        BoundedHTTPFileTransport { request, maximumBytes in
            try await BoundedURLSessionFileLoader.load(
                request,
                maximumBytes: maximumBytes,
                configuration: configuration
            )
        }
    }
}

final class BoundedHTTPFileStaging: @unchecked Sendable {
    static let shared = BoundedHTTPFileStaging()

    private let lock = NSLock()
    private let maximumFiles: Int
    private let maximumAge: TimeInterval
    private var active: Set<URL> = []
    private let root: URL

    init(
        root: URL = FileManager.default.temporaryDirectory.appending(
            path: "TronHTTPDownloads",
            directoryHint: .isDirectory
        ),
        maximumFiles: Int = 32,
        maximumAge: TimeInterval = 24 * 60 * 60
    ) {
        precondition(maximumFiles > 0)
        precondition(maximumAge >= 0)
        self.root = root
        self.maximumFiles = maximumFiles
        self.maximumAge = maximumAge
    }

    func reserveDestination(now: Date = Date()) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let cutoff = now.addingTimeInterval(-maximumAge)
        var candidates = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { !active.contains($0) }
        for candidate in candidates {
            let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile != true || (values?.contentModificationDate ?? .distantPast) < cutoff {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        candidates = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { !active.contains($0) }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left < right
        }
        while active.count + candidates.count >= maximumFiles, let oldest = candidates.first {
            candidates.removeFirst()
            try? FileManager.default.removeItem(at: oldest)
        }
        guard active.count < maximumFiles else { throw URLError(.cannotCreateFile) }
        let destination = root.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        active.insert(destination)
        return destination
    }

    func discard(_ url: URL) {
        lock.lock()
        active.remove(url)
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}

struct BoundedHTTPFileAdmission {
    let maximumBytes: Int64

    init(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = Int64(maximumBytes)
    }

    func admitExpectedLength(_ expectedLength: Int64) throws {
        guard expectedLength < 0 || expectedLength <= maximumBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
    }

    func admitProgress(_ totalBytesWritten: Int64) throws {
        guard totalBytesWritten >= 0, totalBytesWritten <= maximumBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
    }
}

final class BoundedURLSessionFileLoader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let admission: BoundedHTTPFileAdmission
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<BoundedHTTPDownloadedFile, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var stagedURL: URL?
    private var terminalResult: Result<BoundedHTTPDownloadedFile, Error>?

    private init(maximumBytes: Int, configuration: URLSessionConfiguration) {
        admission = BoundedHTTPFileAdmission(maximumBytes: maximumBytes)
        self.configuration = configuration
    }

    static func load(
        _ request: URLRequest,
        maximumBytes: Int,
        configuration: URLSessionConfiguration
    ) async throws -> BoundedHTTPDownloadedFile {
        let loader = BoundedURLSessionFileLoader(
            maximumBytes: maximumBytes,
            configuration: configuration
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(request, continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func start(
        _ request: URLRequest,
        continuation: CheckedContinuation<BoundedHTTPDownloadedFile, Error>
    ) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)

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
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        do {
            try admission.admitExpectedLength(totalBytesExpectedToWrite)
            try admission.admitProgress(totalBytesWritten)
        } catch {
            downloadTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            try admission.admitExpectedLength(response.expectedContentLength)
            let values = try location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw URLError(.cannotDecodeContentData)
            }
            try admission.admitProgress(Int64(fileSize))

            let destination = try BoundedHTTPFileStaging.shared.reserveDestination()
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: destination.path
                )
            } catch {
                BoundedHTTPFileStaging.shared.discard(destination)
                throw error
            }
            lock.lock()
            guard terminalResult == nil else {
                lock.unlock()
                BoundedHTTPFileStaging.shared.discard(destination)
                return
            }
            stagedURL = destination
            lock.unlock()
            finish(.success(BoundedHTTPDownloadedFile(
                url: destination,
                response: response,
                byteCount: Int64(fileSize)
            )))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<BoundedHTTPDownloadedFile, Error>) {
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
        let stagedURL = self.stagedURL
        if case .failure = result {
            self.stagedURL = nil
        }
        lock.unlock()

        session?.invalidateAndCancel()
        if case .failure = result, let stagedURL {
            BoundedHTTPFileStaging.shared.discard(stagedURL)
        }
        continuation?.resume(with: result)
    }
}

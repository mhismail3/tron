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
    private let maximumTotalBytes: Int64
    private let maximumAge: TimeInterval
    private let minimumFreeBytes: Int64 = 64 * 1_024 * 1_024
    private var active: [URL: Int64] = [:]
    private let root: URL

    init(
        root: URL = FileManager.default.temporaryDirectory.appending(
            path: "TronHTTPDownloads",
            directoryHint: .isDirectory
        ),
        maximumFiles: Int = 32,
        maximumTotalBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        maximumAge: TimeInterval = 24 * 60 * 60
    ) {
        precondition(maximumFiles > 0)
        precondition(maximumTotalBytes >= 0)
        precondition(maximumAge >= 0)
        self.root = root
        self.maximumFiles = maximumFiles
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAge = maximumAge
    }

    func reserveDestination(incomingBytes: Int64 = 0, now: Date = Date()) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard incomingBytes >= 0, incomingBytes <= maximumTotalBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw URLError(.cannotCreateFile)
        }
        let cutoff = now.addingTimeInterval(-maximumAge)
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var candidates: [(url: URL, size: Int64, modified: Date)] = []
        for url in urls where active[url] == nil {
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified >= cutoff,
                  let size = values?.fileSize,
                  size >= 0,
                  Int64(size) <= maximumTotalBytes else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            candidates.append((url, Int64(size), modified))
        }
        candidates.sort { $0.modified < $1.modified }
        let activeBytes = try Self.checkedTotal(active.values)
        var retainedBytes = try Self.checkedTotal(
            candidates.map(\.size),
            startingAt: activeBytes
        )
        while active.count + candidates.count >= maximumFiles
            || Self.exceeds(retainedBytes, adding: incomingBytes, limit: maximumTotalBytes) {
            guard let oldest = candidates.first else { throw URLError(.cannotCreateFile) }
            candidates.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            retainedBytes -= oldest.size
        }
        guard active.count < maximumFiles,
              !Self.exceeds(retainedBytes, adding: incomingBytes, limit: maximumTotalBytes) else {
            throw URLError(.cannotCreateFile)
        }
        if let available = try root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ]).volumeAvailableCapacityForImportantUsage,
           Self.exceeds(incomingBytes, adding: minimumFreeBytes, limit: available) {
            throw URLError(.cannotCreateFile)
        }
        let destination = root.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        active[destination] = incomingBytes
        return destination
    }

    private static func checkedTotal<S: Sequence>(
        _ values: S,
        startingAt initial: Int64 = 0
    ) throws -> Int64 where S.Element == Int64 {
        var total = initial
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow, value >= 0 else { throw URLError(.cannotCreateFile) }
            total = next
        }
        return total
    }

    private static func exceeds(_ value: Int64, adding increment: Int64, limit: Int64) -> Bool {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow || increment < 0 || sum > limit
    }

    func discard(_ url: URL) {
        lock.lock()
        active.removeValue(forKey: url)
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
    private var remainingResumeAttempts = 2
    private var terminalResult: Result<BoundedHTTPDownloadedFile, Error>?

    private init(
        maximumBytes: Int,
        configuration: URLSessionConfiguration,
        stagedURL: URL
    ) {
        admission = BoundedHTTPFileAdmission(maximumBytes: maximumBytes)
        self.configuration = configuration
        self.stagedURL = stagedURL
    }

    static func load(
        _ request: URLRequest,
        maximumBytes: Int,
        configuration: URLSessionConfiguration
    ) async throws -> BoundedHTTPDownloadedFile {
        let stagedURL = try BoundedHTTPFileStaging.shared.reserveDestination(
            incomingBytes: Int64(maximumBytes)
        )
        let loader = BoundedURLSessionFileLoader(
            maximumBytes: maximumBytes,
            configuration: configuration,
            stagedURL: stagedURL
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

            lock.lock()
            guard terminalResult == nil, let destination = stagedURL else {
                lock.unlock()
                return
            }
            do {
                // Keep cancellation serialized with publication so a cancelled
                // move cannot recreate a file after its reservation is retired.
                try FileManager.default.moveItem(at: location, to: destination)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: destination.path
                )
                lock.unlock()
            } catch {
                lock.unlock()
                throw error
            }
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
            if resumeAfterTransientFailure(error) { return }
            finish(.failure(error))
        }
    }

    private func resumeAfterTransientFailure(_ error: Error) -> Bool {
        let failure = error as NSError
        guard let resumeData = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
              !resumeData.isEmpty else { return false }
        lock.lock()
        guard terminalResult == nil,
              remainingResumeAttempts > 0,
              let session else {
            lock.unlock()
            return false
        }
        remainingResumeAttempts -= 1
        let resumedTask = session.downloadTask(withResumeData: resumeData)
        task = resumedTask
        lock.unlock()
        resumedTask.resume()
        return true
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

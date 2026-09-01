import Foundation
import ImageIO
import Observation
import UIKit

struct ChatMediaIdentity: Hashable, Sendable {
    let profileID: String
    let lifecycleGeneration: Int
    let blobID: String
}

struct ChatMediaPayload: Sendable {
    let data: Data
    let mimeType: String
}

typealias ChatMediaFetch = @Sendable (ChatMediaIdentity) async throws -> ChatMediaPayload
typealias ChatMediaThumbnailDecode = @Sendable (Data) async throws -> (UIImage, Int)
typealias ChatMediaFullPreviewDecode = @Sendable (Data) async throws -> UIImage
typealias ChatMediaAdmission = @MainActor (ChatMediaIdentity) -> Bool

enum ChatMediaLoadError: Error, Equatable, Sendable {
    case capacityExceeded
    case encodedPayloadTooLarge
    case decodedPayloadTooLarge
    case invalidImage
    case staleIdentity
}

/// The terminal state of one identity-scoped media request. Cancellation is
/// explicit: a cell may leave the hierarchy without allowing an old
/// completion to masquerade as a failed request or install a stale image.
enum ChatMediaLoadState: Equatable, Sendable {
    case idle
    case loading
    case succeeded
    case failed
    case cancelled
}

enum ChatMediaPolicy {
    static let maximumDecodedThumbnailBytes = 4 * 1_024 * 1_024
    static let maximumThumbnailCount = 64
    static let maximumThumbnailPixelDimension = 192
    static let maximumFullPreviewPixelDimension = 4_096
    static let maximumDecodedFullPreviewBytes = 64 * 1_024 * 1_024
    static let maximumEncodedBytes = 25 * 1_024 * 1_024
    static let maximumConcurrentPreparations = 1
    static let maximumThumbnailFlights = 32

    static func admitsEncodedByteCount(_ count: Int) -> Bool {
        count >= 0 && count <= maximumEncodedBytes
    }

    static func decodedByteCount(bytesPerRow: Int, height: Int, maximum: Int) -> Int? {
        guard bytesPerRow >= 0, height >= 0, maximum >= 0 else { return nil }
        let (count, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, count <= maximum else { return nil }
        return count
    }
}

private actor ChatMediaWorkLimiter {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrent: Int
    private let maximumWaiters: Int
    private var active = 0
    private var nextID: UInt64 = 0
    private var waiters: [Waiter] = []

    init(maximumConcurrent: Int, maximumWaiters: Int) {
        precondition(maximumConcurrent > 0 && maximumWaiters >= 0)
        self.maximumConcurrent = maximumConcurrent
        self.maximumWaiters = maximumWaiters
    }

    func run<T: Sendable>(
        priority: Bool = false,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority: priority)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(priority: Bool) async throws {
        try Task.checkCancellation()
        if active < maximumConcurrent {
            active += 1
            return
        }
        guard waiters.count < maximumWaiters else { throw ChatMediaLoadError.capacityExceeded }
        nextID &+= 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(id: id, continuation: continuation)
                if priority { waiters.insert(waiter, at: 0) }
                else { waiters.append(waiter) }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        active = max(0, active - 1)
    }
}

struct ChatMediaMetrics: Equatable, Sendable {
    let thumbnailCount: Int
    let decodedThumbnailBytes: Int
    let thumbnailFlights: Int
    let hasFullPreviewFlight: Bool
}

@MainActor
@Observable
final class ChatMediaLoader {
    private struct Thumbnail: Sendable {
        let image: UIImage
        let decodedBytes: Int
        var accessOrdinal: UInt64
    }

    private struct ThumbnailFlight {
        let token: UInt64
        let invalidationGeneration: UInt64
        let task: Task<(UIImage, Int), Error>
    }

    private enum PreviewKind: Hashable, Sendable {
        case image
        case file
    }

    private enum PreviewValue: Sendable {
        case image(UIImage)
        case file(ChatMediaPayload)
    }

    private struct PreviewFlight {
        let identity: ChatMediaIdentity
        let kind: PreviewKind
        let token: UInt64
        let invalidationGeneration: UInt64
        let previewGeneration: UInt64
        let task: Task<PreviewValue, Error>
        var leases: Set<UUID>
    }

    private let fetch: ChatMediaFetch
    private let thumbnailDecode: ChatMediaThumbnailDecode
    private let fullPreviewDecode: ChatMediaFullPreviewDecode
    private let admits: ChatMediaAdmission
    private let workLimiter = ChatMediaWorkLimiter(
        maximumConcurrent: ChatMediaPolicy.maximumConcurrentPreparations,
        maximumWaiters: ChatMediaPolicy.maximumThumbnailFlights
    )
    private var thumbnails: [ChatMediaIdentity: Thumbnail] = [:]
    private var thumbnailFlights: [ChatMediaIdentity: ThumbnailFlight] = [:]
    private var previewFlight: PreviewFlight?
    private var decodedThumbnailBytes = 0
    private var ordinal: UInt64 = 0
    private var invalidationGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    #if HOSTED_TEST
    private var hostedThumbnailFlightWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var hostedPreviewLeaseWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var hostedFilePreviewWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(
        fetch: @escaping ChatMediaFetch,
        thumbnailDecode: ChatMediaThumbnailDecode? = nil,
        fullPreviewDecode: ChatMediaFullPreviewDecode? = nil,
        admits: @escaping ChatMediaAdmission
    ) {
        self.fetch = fetch
        self.thumbnailDecode = thumbnailDecode ?? { data in
            try await Task.detached(priority: .userInitiated) {
                try Self.decodeThumbnail(data)
            }.value
        }
        self.fullPreviewDecode = fullPreviewDecode ?? { data in
            try await Task.detached(priority: .userInitiated) {
                try Self.decodeFullPreview(data)
            }.value
        }
        self.admits = admits
    }

    func thumbnail(for identity: ChatMediaIdentity) async throws -> UIImage {
        try await thumbnail(for: identity, decode: thumbnailDecode)
    }

    /// Aliases a composer thumbnail that was already decoded and bounded
    /// off-main under the exact canonical blob identity. Settlement performs no
    /// ImageIO work and can therefore install the canonical row immediately.
    func seedPreparedThumbnail(
        _ prepared: ComposerPreparedAttachmentThumbnail,
        for identity: ChatMediaIdentity
    ) throws {
        guard admits(identity) else { throw ChatMediaLoadError.staleIdentity }
        let (decodedBytes, overflow) = prepared.image.bytesPerRow.multipliedReportingOverflow(
            by: prepared.image.height
        )
        guard !overflow,
              prepared.encodedData.count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes,
              prepared.image.width <= ComposerAttachmentPreviewPolicy.maximumPixelDimension,
              prepared.image.height <= ComposerAttachmentPreviewPolicy.maximumPixelDimension,
              prepared.decodedBytes == decodedBytes,
              decodedBytes <= ChatMediaPolicy.maximumDecodedThumbnailBytes else {
            throw ChatMediaLoadError.decodedPayloadTooLarge
        }
        if thumbnails[identity] != nil { return }
        admitThumbnail(
            UIImage(cgImage: prepared.image),
            decodedBytes: prepared.decodedBytes,
            for: identity
        )
    }

    /// Read-only synchronous lookup used by a newly mounted canonical chip so
    /// it never paints a loading placeholder over the thumbnail just displayed.
    func cachedThumbnail(for identity: ChatMediaIdentity) -> UIImage? {
        guard admits(identity) else { return nil }
        return thumbnails[identity]?.image
    }

    /// Retires one presentation-owned flight. The cache remains valid, but a
    /// detached chip's next generation must not inherit the cancelled flight.
    /// Late completion is rejected by the flight token and cannot install.
    func cancelThumbnail(for identity: ChatMediaIdentity) {
        guard let flight = thumbnailFlights.removeValue(forKey: identity) else { return }
        flight.task.cancel()
        hostedNotifyMediaCounts()
    }

    func fileThumbnail(
        for identity: ChatMediaIdentity,
        name: String,
        mimeType: String
    ) async throws -> UIImage {
        try await thumbnail(for: identity) { data in
            guard let preview = ComposerAttachmentPreviewPolicy.prepareSynchronously(
                data,
                mimeType: mimeType,
                name: name
            ), let image = UIImage(data: preview), let cgImage = image.cgImage,
                  let decodedBytes = ChatMediaPolicy.decodedByteCount(
                    bytesPerRow: cgImage.bytesPerRow,
                    height: cgImage.height,
                    maximum: ChatMediaPolicy.maximumDecodedThumbnailBytes
                  ) else {
                throw ChatMediaLoadError.invalidImage
            }
            return (image, decodedBytes)
        }
    }

    private func thumbnail(
        for identity: ChatMediaIdentity,
        decode: @escaping ChatMediaThumbnailDecode
    ) async throws -> UIImage {
        guard admits(identity) else { throw ChatMediaLoadError.staleIdentity }
        if var cached = thumbnails[identity] {
            ordinal &+= 1
            cached.accessOrdinal = ordinal
            thumbnails[identity] = cached
            return cached.image
        }

        let flight: ThumbnailFlight
        if let existing = thumbnailFlights[identity] {
            flight = existing
        } else {
            guard thumbnailFlights.count < ChatMediaPolicy.maximumThumbnailFlights else {
                throw ChatMediaLoadError.capacityExceeded
            }
            ordinal &+= 1
            let token = ordinal
            let invalidationGeneration = self.invalidationGeneration
            let fetch = self.fetch
            let workLimiter = self.workLimiter
            let task = Task {
                try await workLimiter.run {
                    let payload = try await fetch(identity)
                    guard ChatMediaPolicy.admitsEncodedByteCount(payload.data.count) else {
                        throw ChatMediaLoadError.encodedPayloadTooLarge
                    }
                    return try await decode(payload.data)
                }
            }
            flight = ThumbnailFlight(
                token: token,
                invalidationGeneration: invalidationGeneration,
                task: task
            )
            thumbnailFlights[identity] = flight
            hostedNotifyMediaCounts()
        }

        do {
            let value = try await flight.task.value
            guard flight.invalidationGeneration == invalidationGeneration,
                  admits(identity) else { throw ChatMediaLoadError.staleIdentity }
            if thumbnailFlights[identity]?.token == flight.token {
                thumbnailFlights[identity] = nil
                admitThumbnail(value.0, decodedBytes: value.1, for: identity)
            } else if thumbnailFlights[identity] != nil {
                throw ChatMediaLoadError.staleIdentity
            }
            return value.0
        } catch {
            if thumbnailFlights[identity]?.token == flight.token {
                thumbnailFlights[identity] = nil
            }
            throw error
        }
    }

    /// Locally staged composer images share the same single preparation slot as
    /// transcript media without entering the transcript cache or flight state.
    func prepareLocalFullPreview(_ data: Data) async throws -> UIImage {
        guard ChatMediaPolicy.admitsEncodedByteCount(data.count) else {
            throw ChatMediaLoadError.encodedPayloadTooLarge
        }
        let fullPreviewDecode = self.fullPreviewDecode
        return try await workLimiter.run(priority: true) {
            try await fullPreviewDecode(data)
        }
    }

    /// Preview payloads are never inserted into the thumbnail LRU. Images and
    /// files share one exact profile/lifecycle/blob flight and one priority work
    /// slot, so opening a document cannot create a parallel full-payload cache.
    func fullPreview(
        for identity: ChatMediaIdentity,
        leaseID: UUID
    ) async throws -> UIImage {
        guard case .image(let image) = try await previewValue(
            for: identity,
            kind: .image,
            leaseID: leaseID
        ) else { throw ChatMediaLoadError.invalidImage }
        return image
    }

    func filePreviewPayload(
        for identity: ChatMediaIdentity,
        leaseID: UUID
    ) async throws -> ChatMediaPayload {
        guard case .file(let payload) = try await previewValue(
            for: identity,
            kind: .file,
            leaseID: leaseID
        ) else { throw ChatMediaLoadError.invalidImage }
        return payload
    }

    func cancelFullPreview(for identity: ChatMediaIdentity, leaseID: UUID) {
        cancelPreview(for: identity, kind: .image, leaseID: leaseID)
    }

    func cancelFilePreview(for identity: ChatMediaIdentity, leaseID: UUID) {
        cancelPreview(for: identity, kind: .file, leaseID: leaseID)
    }

    private func previewValue(
        for identity: ChatMediaIdentity,
        kind: PreviewKind,
        leaseID: UUID
    ) async throws -> PreviewValue {
        guard admits(identity) else { throw ChatMediaLoadError.staleIdentity }
        let flight: PreviewFlight
        if var current = previewFlight,
           current.identity == identity,
           current.kind == kind {
            current.leases.insert(leaseID)
            previewFlight = current
            hostedNotifyMediaCounts()
            flight = current
        } else {
            previewFlight?.task.cancel()
            previewGeneration &+= 1
            ordinal &+= 1
            let token = ordinal
            let invalidationGeneration = self.invalidationGeneration
            let previewGeneration = self.previewGeneration
            let fetch = self.fetch
            let fullPreviewDecode = self.fullPreviewDecode
            let workLimiter = self.workLimiter
            let task = Task<PreviewValue, Error> {
                try await workLimiter.run(priority: true) {
                    let payload = try await fetch(identity)
                    guard ChatMediaPolicy.admitsEncodedByteCount(payload.data.count) else {
                        throw ChatMediaLoadError.encodedPayloadTooLarge
                    }
                    switch kind {
                    case .image:
                        return .image(try await fullPreviewDecode(payload.data))
                    case .file:
                        return .file(payload)
                    }
                }
            }
            flight = PreviewFlight(
                identity: identity,
                kind: kind,
                token: token,
                invalidationGeneration: invalidationGeneration,
                previewGeneration: previewGeneration,
                task: task,
                leases: [leaseID]
            )
            previewFlight = flight
            hostedNotifyMediaCounts()
        }

        defer { releasePreviewLease(token: flight.token, leaseID: leaseID) }
        let value = try await flight.task.value
        guard !Task.isCancelled else { throw CancellationError() }
        guard flight.invalidationGeneration == invalidationGeneration,
              flight.previewGeneration == previewGeneration,
              admits(identity),
              previewFlight?.token == flight.token,
              previewFlight?.leases.contains(leaseID) == true else {
            throw ChatMediaLoadError.staleIdentity
        }
        return value
    }

    private func cancelPreview(
        for identity: ChatMediaIdentity,
        kind: PreviewKind,
        leaseID: UUID
    ) {
        guard var flight = previewFlight,
              flight.identity == identity,
              flight.kind == kind,
              flight.leases.remove(leaseID) != nil else { return }
        if flight.leases.isEmpty {
            previewGeneration &+= 1
            flight.task.cancel()
            previewFlight = nil
        } else {
            previewFlight = flight
        }
        hostedNotifyMediaCounts()
    }

    func removeAll() {
        invalidationGeneration &+= 1
        previewGeneration &+= 1
        thumbnailFlights.values.forEach { $0.task.cancel() }
        previewFlight?.task.cancel()
        thumbnailFlights.removeAll(keepingCapacity: false)
        previewFlight = nil
        thumbnails.removeAll(keepingCapacity: false)
        decodedThumbnailBytes = 0
        hostedNotifyMediaCounts()
    }

    func metrics() -> ChatMediaMetrics {
        ChatMediaMetrics(
            thumbnailCount: thumbnails.count,
            decodedThumbnailBytes: decodedThumbnailBytes,
            thumbnailFlights: thumbnailFlights.count,
            hasFullPreviewFlight: previewFlight != nil
        )
    }

    nonisolated static func decodeFullPreview(_ data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw ChatMediaLoadError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ChatMediaPolicy.maximumFullPreviewPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ChatMediaLoadError.invalidImage
        }
        guard ChatMediaPolicy.decodedByteCount(
            bytesPerRow: image.bytesPerRow,
            height: image.height,
            maximum: ChatMediaPolicy.maximumDecodedFullPreviewBytes
        ) != nil else {
            throw ChatMediaLoadError.decodedPayloadTooLarge
        }
        return UIImage(cgImage: image)
    }

    nonisolated static func decodeThumbnail(_ data: Data) throws -> (UIImage, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw ChatMediaLoadError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ChatMediaPolicy.maximumThumbnailPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ChatMediaLoadError.invalidImage
        }
        guard let decodedBytes = ChatMediaPolicy.decodedByteCount(
            bytesPerRow: image.bytesPerRow,
            height: image.height,
            maximum: ChatMediaPolicy.maximumDecodedThumbnailBytes
        ) else {
            throw ChatMediaLoadError.decodedPayloadTooLarge
        }
        return (UIImage(cgImage: image), decodedBytes)
    }

    #if HOSTED_TEST
    func hostedWaitForThumbnailFlightCount(_ count: Int) async {
        if thumbnailFlights.count >= count { return }
        await withCheckedContinuation { hostedThumbnailFlightWaiters.append((count, $0)) }
    }

    func hostedWaitForPreviewLeaseCount(_ count: Int) async {
        if (previewFlight?.leases.count ?? 0) >= count { return }
        await withCheckedContinuation { hostedPreviewLeaseWaiters.append((count, $0)) }
    }

    func hostedWaitForFilePreviewFlight() async {
        if previewFlight?.kind == .file { return }
        await withCheckedContinuation { hostedFilePreviewWaiters.append($0) }
    }
    #endif

    private func hostedNotifyMediaCounts() {
        #if HOSTED_TEST
        let readyThumbnail = hostedThumbnailFlightWaiters.filter { thumbnailFlights.count >= $0.0 }
        hostedThumbnailFlightWaiters.removeAll { thumbnailFlights.count >= $0.0 }
        readyThumbnail.forEach { $0.1.resume() }
        let previewCount = previewFlight?.leases.count ?? 0
        let readyPreview = hostedPreviewLeaseWaiters.filter { previewCount >= $0.0 }
        hostedPreviewLeaseWaiters.removeAll { previewCount >= $0.0 }
        readyPreview.forEach { $0.1.resume() }
        if previewFlight?.kind == .file {
            let readyFile = hostedFilePreviewWaiters
            hostedFilePreviewWaiters.removeAll()
            readyFile.forEach { $0.resume() }
        }
        #endif
    }

    private func releasePreviewLease(token: UInt64, leaseID: UUID) {
        guard var flight = previewFlight, flight.token == token else { return }
        flight.leases.remove(leaseID)
        if flight.leases.isEmpty { previewFlight = nil }
        else { previewFlight = flight }
        hostedNotifyMediaCounts()
    }

    private func admitThumbnail(
        _ image: UIImage,
        decodedBytes: Int,
        for identity: ChatMediaIdentity
    ) {
        guard decodedBytes <= ChatMediaPolicy.maximumDecodedThumbnailBytes else { return }
        if let previous = thumbnails.removeValue(forKey: identity) {
            decodedThumbnailBytes -= previous.decodedBytes
        }
        ordinal &+= 1
        thumbnails[identity] = Thumbnail(
            image: image,
            decodedBytes: decodedBytes,
            accessOrdinal: ordinal
        )
        decodedThumbnailBytes += decodedBytes
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while thumbnails.count > ChatMediaPolicy.maximumThumbnailCount
            || decodedThumbnailBytes > ChatMediaPolicy.maximumDecodedThumbnailBytes {
            guard let oldest = thumbnails.min(by: {
                if $0.value.accessOrdinal != $1.value.accessOrdinal {
                    return $0.value.accessOrdinal < $1.value.accessOrdinal
                }
                if $0.key.profileID != $1.key.profileID {
                    return $0.key.profileID < $1.key.profileID
                }
                if $0.key.lifecycleGeneration != $1.key.lifecycleGeneration {
                    return $0.key.lifecycleGeneration < $1.key.lifecycleGeneration
                }
                return $0.key.blobID < $1.key.blobID
            })?.key, let removed = thumbnails.removeValue(forKey: oldest) else { return }
            decodedThumbnailBytes -= removed.decodedBytes
        }
    }
}

import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import UIKit
import TronMobileCore

struct ChatMediaIdentity: Hashable, Sendable {
    let profileID: String
    let lifecycleGeneration: Int
    let blobID: String
    let sessionID: String?

    init(
        profileID: String,
        lifecycleGeneration: Int,
        blobID: String,
        sessionID: String? = nil
    ) {
        self.profileID = profileID
        self.lifecycleGeneration = lifecycleGeneration
        self.blobID = blobID
        self.sessionID = sessionID
    }
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

protocol ChatInlineArtifact: Sendable {
    var accountedBytes: Int { get }
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
    static let maximumRetainedInlineArtifacts = 8
    static let maximumRetainedInlineArtifactBytes = 4 * 1_024 * 1_024
    static let maximumRetainedInlineArtifactValueBytes = 1 * 1_024 * 1_024
    static let maximumInlineArtifactFlights = 4

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

actor LiveImagePreparation {
    static let shared = LiveImagePreparation()
    private var preparing = false

    func prepare(_ operation: @escaping @Sendable () throws -> UIImage) async throws -> UIImage? {
        try Task.checkCancellation()
        guard !preparing else { return nil }
        preparing = true
        defer { preparing = false }
        let decoding = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let image = try operation()
            try Task.checkCancellation()
            return image
        }
        let image = try await withTaskCancellationHandler {
            try await decoding.value
        } onCancel: {
            decoding.cancel()
        }
        try Task.checkCancellation()
        return image
    }
}

extension GatewayClient.LiveFrame {
    func decode() async throws -> UIImage? {
        try await LiveImagePreparation.shared.prepare { try self.decodeImage() }
    }

    private func decodeImage() throws -> UIImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else {
            throw GatewayClient.LiveError.invalidResponse
        }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), image.width == width, image.height == height,
              ChatMediaPolicy.decodedByteCount(bytesPerRow: image.bytesPerRow, height: image.height,
                maximum: Self.maximumDecodedBytes) != nil else { throw GatewayClient.LiveError.invalidResponse }
        try Task.checkCancellation()
        return UIImage(cgImage: image)
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
    let retainedInlineArtifactCount: Int
    let retainedInlineArtifactBytes: Int
    let inlineArtifactFlights: Int
}

@MainActor
@Observable
final class ChatMediaLoader {
    private struct Thumbnail: Sendable {
        let image: UIImage
        let decodedBytes: Int
        var accessOrdinal: UInt64
    }

    private struct RetainedInlineArtifact {
        let value: any ChatInlineArtifact
        var accessOrdinal: UInt64
    }

    private struct InlineArtifactFlight {
        let token: UInt64
        let task: Task<any ChatInlineArtifact, Error>
    }

    private struct ThumbnailFlight {
        let token: UInt64
        let invalidationGeneration: UInt64
        let task: Task<(UIImage, Int), Error>
        var waiters: Int
    }

    private enum PreviewKind: Hashable, Sendable {
        case image
        case file
    }

    private enum PreviewValue: Sendable {
        case image(UIImage)
        case file(ChatMediaPayload)
    }

    private final class PreviewRequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct PreviewRequest {
        let presentationLeaseID: UUID
        let cancellation: PreviewRequestCancellation
    }

    private struct PreviewFlight {
        let identity: ChatMediaIdentity
        let kind: PreviewKind
        let token: UInt64
        let invalidationGeneration: UInt64
        let previewGeneration: UInt64
        let task: Task<PreviewValue, Error>
        var requests: [UInt64: PreviewRequest]
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
    private var inlineArtifacts: [ChatMediaIdentity: RetainedInlineArtifact] = [:]
    private var inlineArtifactFlights: [ChatMediaIdentity: InlineArtifactFlight] = [:]
    private var inlineArtifactSlotsInUse = 0
    private var inlineArtifactSlotWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var inlineArtifactSlotWaiterOrder: [UInt64] = []
    private var retainedInlineArtifactBytes = 0
    private var decodedThumbnailBytes = 0
    private var ordinal: UInt64 = 0
    private var invalidationGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    #if HOSTED_TEST
    private var hostedThumbnailFlightWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var hostedPreviewAdmissionCount = 0
    private var hostedPreviewAdmissionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var hostedBeforePreviewCancellationCleanup: (@MainActor () async -> Void)?
    var hostedAfterPreviewCancellationCleanup: (@MainActor () async -> Void)?
    private var hostedPreviewLeaseWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var hostedFilePreviewWaiters: [CheckedContinuation<Void, Never>] = []
    private var hostedInlineArtifactFlightWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
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

    func cachedThumbnail(for identity: ChatMediaIdentity) -> UIImage? {
        guard admits(identity) else { return nil }
        return thumbnails[identity]?.image
    }

    func retainedInlineArtifact<A: ChatInlineArtifact>(
        for identity: ChatMediaIdentity,
        as type: A.Type
    ) -> A? {
        guard admits(identity) else { return nil }
        return inlineArtifacts[identity]?.value as? A
    }

    func inlineArtifact<A: ChatInlineArtifact>(
        for identity: ChatMediaIdentity,
        prepare: @escaping @Sendable (ChatMediaPayload) async throws -> A
    ) async throws -> A {
        guard admits(identity) else { throw ChatMediaLoadError.staleIdentity }
        if let retained = retainedInlineArtifact(for: identity, as: A.self) { return retained }

        if let existing = inlineArtifactFlights[identity] {
            return try await inlineArtifact(joining: existing, identity: identity)
        }

        await acquireInlineArtifactSlot()
        do {
            try Task.checkCancellation()
            guard admits(identity) else { throw ChatMediaLoadError.staleIdentity }
            if let retained = retainedInlineArtifact(for: identity, as: A.self) {
                releaseInlineArtifactSlot()
                return retained
            }
            if let existing = inlineArtifactFlights[identity] {
                releaseInlineArtifactSlot()
                return try await inlineArtifact(joining: existing, identity: identity)
            }
        } catch {
            releaseInlineArtifactSlot()
            throw error
        }

        ordinal &+= 1
        let token = ordinal
        let invalidationGeneration = self.invalidationGeneration
        let fetch = self.fetch
        let workLimiter = self.workLimiter
        let task = Task<any ChatInlineArtifact, Error> { [weak self] in
            let payload = try await workLimiter.run {
                let payload = try await fetch(identity)
                guard ChatMediaPolicy.admitsEncodedByteCount(payload.data.count) else {
                    throw ChatMediaLoadError.encodedPayloadTooLarge
                }
                return payload
            }
            try Task.checkCancellation()
            let artifact = try await prepare(payload)
            guard let self, !Task.isCancelled,
                  self.invalidationGeneration == invalidationGeneration,
                  self.admits(identity) else { throw ChatMediaLoadError.staleIdentity }
            self.retainInlineArtifact(artifact, for: identity)
            return artifact
        }
        let flight = InlineArtifactFlight(token: token, task: task)
        inlineArtifactFlights[identity] = flight
        hostedNotifyMediaCounts()
        return try await inlineArtifact(joining: flight, identity: identity)
    }

    private func inlineArtifact<A: ChatInlineArtifact>(
        joining flight: InlineArtifactFlight,
        identity: ChatMediaIdentity
    ) async throws -> A {
        do {
            let artifact = try await flight.task.value
            retireInlineArtifactFlight(identity: identity, token: flight.token)
            guard let typed = artifact as? A else { throw ChatMediaLoadError.staleIdentity }
            return typed
        } catch {
            retireInlineArtifactFlight(identity: identity, token: flight.token)
            throw error
        }
    }

    private func acquireInlineArtifactSlot() async {
        guard inlineArtifactSlotsInUse >= ChatMediaPolicy.maximumInlineArtifactFlights else {
            inlineArtifactSlotsInUse += 1
            return
        }
        ordinal &+= 1
        let token = ordinal
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inlineArtifactSlotWaiters[token] = continuation
            inlineArtifactSlotWaiterOrder.append(token)
        }
    }

    private func releaseInlineArtifactSlot() {
        while let token = inlineArtifactSlotWaiterOrder.first {
            inlineArtifactSlotWaiterOrder.removeFirst()
            guard let continuation = inlineArtifactSlotWaiters.removeValue(forKey: token) else { continue }
            continuation.resume()
            return
        }
        inlineArtifactSlotsInUse = max(0, inlineArtifactSlotsInUse - 1)
    }

    private func retireInlineArtifactFlight(identity: ChatMediaIdentity, token: UInt64) {
        guard inlineArtifactFlights[identity]?.token == token else { return }
        inlineArtifactFlights[identity] = nil
        releaseInlineArtifactSlot()
        hostedNotifyMediaCounts()
    }

    private func retainInlineArtifact(_ artifact: any ChatInlineArtifact, for identity: ChatMediaIdentity) {
        let accounted = max(0, artifact.accountedBytes)
        guard accounted <= ChatMediaPolicy.maximumRetainedInlineArtifactValueBytes else { return }
        if let previous = inlineArtifacts.removeValue(forKey: identity) {
            retainedInlineArtifactBytes -= previous.value.accountedBytes
        }
        ordinal &+= 1
        inlineArtifacts[identity] = RetainedInlineArtifact(value: artifact, accessOrdinal: ordinal)
        retainedInlineArtifactBytes += accounted
        evictInlineArtifactsIfNeeded()
    }

    private func evictInlineArtifactsIfNeeded() {
        while inlineArtifacts.count > ChatMediaPolicy.maximumRetainedInlineArtifacts
            || retainedInlineArtifactBytes > ChatMediaPolicy.maximumRetainedInlineArtifactBytes {
            guard let oldest = inlineArtifacts.min(by: {
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
            })?.key, let removed = inlineArtifacts.removeValue(forKey: oldest) else { return }
            retainedInlineArtifactBytes -= removed.value.accountedBytes
        }
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
        if var existing = thumbnailFlights[identity] {
            existing.waiters += 1
            thumbnailFlights[identity] = existing
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
                task: task,
                waiters: 1
            )
            thumbnailFlights[identity] = flight
            Task { [weak self] in
                _ = await task.result
                self?.retireCompletedThumbnailFlight(identity: identity, token: token)
            }
            hostedNotifyMediaCounts()
        }

        var taskCompleted = false
        do {
            let value: (UIImage, Int)
            do {
                value = try await flight.task.value
                taskCompleted = true
            } catch {
                taskCompleted = true
                throw error
            }
            try Task.checkCancellation()
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
            if Task.isCancelled {
                if taskCompleted { finishCancelledThumbnailWaiter(identity: identity, token: flight.token) }
                else { removeCancelledThumbnailWaiter(identity: identity, token: flight.token) }
            } else if thumbnailFlights[identity]?.token == flight.token {
                thumbnailFlights[identity] = nil
                hostedNotifyMediaCounts()
            }
            throw error
        }
    }

    private func removeCancelledThumbnailWaiter(identity: ChatMediaIdentity, token: UInt64) {
        guard var flight = thumbnailFlights[identity], flight.token == token else { return }
        flight.waiters = max(0, flight.waiters - 1)
        thumbnailFlights[identity] = flight
    }

    private func finishCancelledThumbnailWaiter(identity: ChatMediaIdentity, token: UInt64) {
        guard var flight = thumbnailFlights[identity], flight.token == token else { return }
        flight.waiters = max(0, flight.waiters - 1)
        if flight.waiters == 0 {
            thumbnailFlights[identity] = nil
            hostedNotifyMediaCounts()
        } else {
            thumbnailFlights[identity] = flight
        }
    }

    private func retireCompletedThumbnailFlight(identity: ChatMediaIdentity, token: UInt64) {
        guard let flight = thumbnailFlights[identity], flight.token == token, flight.waiters == 0 else { return }
        thumbnailFlights[identity] = nil
        hostedNotifyMediaCounts()
    }

    func prepareLocalFullPreview(_ data: Data) async throws -> UIImage {
        guard ChatMediaPolicy.admitsEncodedByteCount(data.count) else {
            throw ChatMediaLoadError.encodedPayloadTooLarge
        }
        let fullPreviewDecode = self.fullPreviewDecode
        return try await workLimiter.run(priority: true) {
            try await fullPreviewDecode(data)
        }
    }

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
        ordinal &+= 1
        let requestToken = ordinal
        let cancellation = PreviewRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard admits(identity) else { throw ChatMediaLoadError.staleIdentity }
            pruneCancelledPreviewRequests()
            let flight: PreviewFlight
            let request = PreviewRequest(presentationLeaseID: leaseID, cancellation: cancellation)
            if var current = previewFlight,
               current.identity == identity, current.kind == kind {
                current.requests[requestToken] = request
                previewFlight = current
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
                        case .image: return .image(try await fullPreviewDecode(payload.data))
                        case .file: return .file(payload)
                        }
                    }
                }
                flight = PreviewFlight(identity: identity, kind: kind, token: token,
                    invalidationGeneration: invalidationGeneration, previewGeneration: previewGeneration,
                    task: task, requests: [requestToken: request])
                previewFlight = flight
            }
            hostedNotifyMediaCounts()
            #if HOSTED_TEST
            hostedPreviewAdmissionCount += 1
            let ready = hostedPreviewAdmissionWaiters.filter { hostedPreviewAdmissionCount >= $0.0 }
            hostedPreviewAdmissionWaiters.removeAll { hostedPreviewAdmissionCount >= $0.0 }
            ready.forEach { $0.1.resume() }
            #endif
            defer { releasePreviewRequest(flightToken: flight.token, requestToken: requestToken) }
            guard !cancellation.isCancelled else { throw CancellationError() }
            let value = try await flight.task.value
            try Task.checkCancellation()
            guard flight.invalidationGeneration == invalidationGeneration,
                  flight.previewGeneration == previewGeneration,
                  admits(identity), previewFlight?.token == flight.token,
                  previewFlight?.requests[requestToken] != nil else {
                throw ChatMediaLoadError.staleIdentity
            }
            return value
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if HOSTED_TEST
                await self.hostedBeforePreviewCancellationCleanup?()
                #endif
                if let flight = self.previewFlight, flight.requests[requestToken] != nil {
                    self.releasePreviewRequest(flightToken: flight.token, requestToken: requestToken)
                }
                #if HOSTED_TEST
                await self.hostedAfterPreviewCancellationCleanup?()
                #endif
            }
        }
    }

    private func pruneCancelledPreviewRequests() {
        guard var flight = previewFlight else { return }
        flight.requests = flight.requests.filter { !$0.value.cancellation.isCancelled }
        if flight.requests.isEmpty {
            previewGeneration &+= 1
            flight.task.cancel()
            previewFlight = nil
        } else { previewFlight = flight }
    }

    private func cancelPreview(
        for identity: ChatMediaIdentity,
        kind: PreviewKind,
        leaseID: UUID
    ) {
        guard var flight = previewFlight, flight.identity == identity, flight.kind == kind else { return }
        flight.requests = flight.requests.filter { $0.value.presentationLeaseID != leaseID }
        if flight.requests.isEmpty {
            previewGeneration &+= 1
            flight.task.cancel()
            previewFlight = nil
        } else { previewFlight = flight }
        hostedNotifyMediaCounts()
    }

    func removeAll() {
        invalidationGeneration &+= 1
        previewGeneration &+= 1
        thumbnailFlights.values.forEach { $0.task.cancel() }
        previewFlight?.task.cancel()
        inlineArtifactFlights.values.forEach { $0.task.cancel() }
        thumbnailFlights.removeAll(keepingCapacity: false)
        previewFlight = nil
        inlineArtifactFlights.removeAll(keepingCapacity: false)
        thumbnails.removeAll(keepingCapacity: false)
        inlineArtifacts.removeAll(keepingCapacity: false)
        retainedInlineArtifactBytes = 0
        decodedThumbnailBytes = 0
        hostedNotifyMediaCounts()
    }

    func metrics() -> ChatMediaMetrics {
        ChatMediaMetrics(
            thumbnailCount: thumbnails.count,
            decodedThumbnailBytes: decodedThumbnailBytes,
            thumbnailFlights: thumbnailFlights.count,
            hasFullPreviewFlight: previewFlight != nil,
            retainedInlineArtifactCount: inlineArtifacts.count,
            retainedInlineArtifactBytes: retainedInlineArtifactBytes,
            inlineArtifactFlights: inlineArtifactFlights.count
        )
    }

    private nonisolated static func decodeImage(
        _ data: Data, maximumDimension: Int, maximumBytes: Int
    ) throws -> (UIImage, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw ChatMediaLoadError.invalidImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw ChatMediaLoadError.invalidImage
        }
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.doubleValue ?? 16
        guard depth.isFinite, depth > 0, depth <= 32 else { throw ChatMediaLoadError.invalidImage }
        let edge = min(Double(maximumDimension), max(width, height))
        let scale = edge / max(width, height)
        let pixelBytes = ceil(width * scale) * ceil(height * scale) * 4 * ceil(depth / 8)
        let budget = Double(maximumBytes) - 64 * edge
        let dimension = max(1, Int(floor(edge * min(1, sqrt(budget / pixelBytes)))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceShouldAllowFloat: false,
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
            bytesPerRow: image.bytesPerRow, height: image.height, maximum: maximumBytes
        ) else { throw ChatMediaLoadError.decodedPayloadTooLarge }
        return (UIImage(cgImage: image), decodedBytes)
    }

    nonisolated static func decodeFullPreview(_ data: Data) throws -> UIImage {
        try decodeImage(data, maximumDimension: ChatMediaPolicy.maximumFullPreviewPixelDimension,
                        maximumBytes: ChatMediaPolicy.maximumDecodedFullPreviewBytes).0
    }

    nonisolated static func decodeThumbnail(_ data: Data) throws -> (UIImage, Int) {
        try decodeImage(data, maximumDimension: ChatMediaPolicy.maximumThumbnailPixelDimension,
                        maximumBytes: ChatMediaPolicy.maximumDecodedThumbnailBytes)
    }

    #if HOSTED_TEST

    func hostedWaitForPreviewAdmissionCount(_ count: Int) async {
        if hostedPreviewAdmissionCount >= count { return }
        await withCheckedContinuation { hostedPreviewAdmissionWaiters.append((count, $0)) }
    }

    #endif

    private func hostedNotifyMediaCounts() {
        #if HOSTED_TEST
        let readyThumbnail = hostedThumbnailFlightWaiters.filter { thumbnailFlights.count >= $0.0 }
        hostedThumbnailFlightWaiters.removeAll { thumbnailFlights.count >= $0.0 }
        readyThumbnail.forEach { $0.1.resume() }
        let readyInline = hostedInlineArtifactFlightWaiters.filter { inlineArtifactFlights.count >= $0.0 }
        hostedInlineArtifactFlightWaiters.removeAll { inlineArtifactFlights.count >= $0.0 }
        readyInline.forEach { $0.1.resume() }
        let previewCount = previewFlight?.requests.count ?? 0
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

    private func releasePreviewRequest(flightToken: UInt64, requestToken: UInt64) {
        guard var flight = previewFlight, flight.token == flightToken,
              flight.requests.removeValue(forKey: requestToken) != nil else { return }
        if flight.requests.isEmpty {
            flight.task.cancel()
            previewFlight = nil
        } else { previewFlight = flight }
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

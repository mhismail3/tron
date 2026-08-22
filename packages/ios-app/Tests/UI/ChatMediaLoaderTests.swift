import Foundation
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Bounded chat media loader")
struct ChatMediaLoaderTests {
    @Test("ratchets match the approved Phase 6 media budget")
    func ratchets() {
        #expect(ChatMediaPolicy.maximumDecodedThumbnailBytes == 4_194_304)
        #expect(ChatMediaPolicy.maximumThumbnailCount == 64)
        #expect(ChatMediaPolicy.maximumThumbnailPixelDimension == 192)
        #expect(ChatMediaPolicy.maximumFullPreviewPixelDimension == 4_096)
        #expect(ChatMediaPolicy.maximumDecodedFullPreviewBytes == 67_108_864)
        #expect(ChatMediaPolicy.maximumEncodedBytes == 26_214_400)
        #expect(ChatMediaPolicy.maximumConcurrentPreparations == 1)
        #expect(ChatMediaPolicy.maximumThumbnailFlights == 32)
        #expect(ChatMediaPolicy.admitsEncodedByteCount(26_214_400))
        #expect(!ChatMediaPolicy.admitsEncodedByteCount(26_214_401))
        #expect(ChatMediaPolicy.decodedByteCount(bytesPerRow: 16_384, height: 4_096, maximum: 67_108_864) == 67_108_864)
        #expect(ChatMediaPolicy.decodedByteCount(bytesPerRow: 16_385, height: 4_096, maximum: 67_108_864) == nil)
        #expect(ChatMediaPolicy.decodedByteCount(bytesPerRow: .max, height: 2, maximum: .max) == nil)
        #expect(ChatMediaPolicy.decodedByteCount(bytesPerRow: -1, height: 1, maximum: 1) == nil)
    }

    @Test("full previews are orientation-correct and bounded before decoded publication")
    func boundedFullPreviewDecode() throws {
        let fixture = try SessionScenarioBuilder(seed: 6_313).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 5_000,
            pixelHeight: 16,
            orientation: .right
        )
        let decoded = try ChatMediaLoader.decodeFullPreview(fixture.encodedData)
        let image = try #require(decoded.cgImage)

        #expect(max(image.width, image.height) == ChatMediaPolicy.maximumFullPreviewPixelDimension)
        #expect(min(image.width, image.height) > 0)
        let decodedBytes = try #require(ChatMediaPolicy.decodedByteCount(
            bytesPerRow: image.bytesPerRow,
            height: image.height,
            maximum: ChatMediaPolicy.maximumDecodedFullPreviewBytes
        ))
        #expect(decodedBytes <= ChatMediaPolicy.maximumDecodedFullPreviewBytes)
        #expect(image.height > image.width)
        #expect(throws: ChatMediaLoadError.invalidImage) {
            try ChatMediaLoader.decodeFullPreview(Data("not-an-image".utf8))
        }
    }

    @Test("oriented high-resolution images downsample off-main to the exact pixel ceiling")
    func downsampling() throws {
        let fixture = try SessionScenarioBuilder(seed: 6_301).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 1_200,
            pixelHeight: 800,
            orientation: .right
        )
        let decoded = try ChatMediaLoader.decodeThumbnail(fixture.encodedData)
        let image = try #require(decoded.0.cgImage)

        #expect(max(image.width, image.height) == ChatMediaPolicy.maximumThumbnailPixelDimension)
        #expect(min(image.width, image.height) > 0)
        #expect(decoded.1 == image.bytesPerRow * image.height)
        #expect(decoded.1 <= 192 * 192 * 4)
    }

    @Test("seeded local previews are synchronous, admission checked, bounded, and avoid fetch")
    func seededThumbnailContinuity() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_314).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 600,
            pixelHeight: 400,
            orientation: .up
        )
        let counter = MediaFetchCounter(payload: .init(
            data: fixture.encodedData,
            mimeType: "image/jpeg"
        ))
        let prepared = try #require(await ComposerAttachmentPreviewPolicy.prepare(
            fixture.encodedData,
            mimeType: "image/jpeg",
            name: "seeded.jpg"
        ))
        let decodeGate = MediaDecodeGate(image: UIImage(cgImage: prepared.image))
        await decodeGate.release()
        var admitted = true
        let loader = ChatMediaLoader(
            fetch: { identity in await counter.fetch(identity) },
            thumbnailDecode: { data in try await decodeGate.decode(data) },
            admits: { _ in admitted }
        )
        let identity = mediaIdentity(blobID: "seeded")

        try loader.seedPreparedThumbnail(prepared, for: identity)
        #expect(loader.cachedThumbnail(for: identity) != nil)
        _ = try await loader.thumbnail(for: identity)
        #expect(await counter.count == 0)
        #expect(await decodeGate.count == 0)

        for index in 0...ChatMediaPolicy.maximumThumbnailCount {
            try loader.seedPreparedThumbnail(
                prepared,
                for: mediaIdentity(blobID: "seeded-\(index)")
            )
        }
        #expect(loader.metrics().thumbnailCount <= ChatMediaPolicy.maximumThumbnailCount)
        #expect(loader.metrics().decodedThumbnailBytes <= ChatMediaPolicy.maximumDecodedThumbnailBytes)

        admitted = false
        #expect(loader.cachedThumbnail(for: identity) == nil)
        #expect(throws: ChatMediaLoadError.staleIdentity) {
            try loader.seedPreparedThumbnail(prepared, for: identity)
        }
    }

    @Test("file thumbnails render bounded first-page text through the shared cache")
    func fileThumbnail() async throws {
        let loader = ChatMediaLoader(
            fetch: { _ in .init(data: Data("line one\nline two".utf8), mimeType: "text/plain") },
            admits: { _ in true }
        )
        let image = try await loader.fileThumbnail(
            for: mediaIdentity(blobID: "document"),
            name: "notes.txt",
            mimeType: "text/plain"
        )
        #expect(image.cgImage?.width == ComposerAttachmentPreviewPolicy.maximumPixelDimension)
        #expect(loader.metrics().thumbnailCount == 1)
    }

    @Test("concurrent requests share one exact identity fetch and decode")
    func singleFlight() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_302).generatedImageFixture(
            format: .png,
            pixelWidth: 600,
            pixelHeight: 400,
            orientation: .up
        )
        let gate = MediaFetchGate(payload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let loader = ChatMediaLoader(
            fetch: { identity in try await gate.fetch(identity) },
            admits: { _ in true }
        )
        let identity = mediaIdentity(blobID: "shared")

        async let first = loader.thumbnail(for: identity)
        async let second = loader.thumbnail(for: identity)
        await gate.waitForStarts(1)
        #expect(await gate.startCount == 1)
        await gate.release()
        let values = try await (first, second)

        #expect(values.0.cgImage?.width == values.1.cgImage?.width)
        #expect(await gate.startCount == 1)
        #expect(loader.metrics().thumbnailCount == 1)
        #expect(loader.metrics().thumbnailFlights == 0)
    }

    @Test("the 33rd distinct thumbnail flight is rejected without starting work")
    func flightCapacity() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_310).generatedImageFixture(
            format: .png,
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: .up
        )
        let gate = MediaFetchGate(payload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let loader = ChatMediaLoader(
            fetch: { identity in try await gate.fetch(identity) },
            admits: { _ in true }
        )
        let flights = (0..<ChatMediaPolicy.maximumThumbnailFlights).map { index in
            Task { try await loader.thumbnail(for: mediaIdentity(blobID: "flight-\(index)")) }
        }
        await loader.hostedWaitForThumbnailFlightCount(ChatMediaPolicy.maximumThumbnailFlights)
        #expect(loader.metrics().thumbnailFlights == ChatMediaPolicy.maximumThumbnailFlights)

        await #expect(throws: ChatMediaLoadError.capacityExceeded) {
            try await loader.thumbnail(for: mediaIdentity(blobID: "flight-overflow"))
        }
        loader.removeAll()
        await gate.release()
        for flight in flights { _ = try? await flight.value }
        #expect(loader.metrics().thumbnailFlights == 0)
    }

    @Test("item LRU evicts the oldest tiny thumbnail deterministically")
    func itemBound() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_303).generatedImageFixture(
            format: .png,
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: .up
        )
        let counter = MediaFetchCounter(payload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let loader = ChatMediaLoader(
            fetch: { identity in await counter.fetch(identity) },
            admits: { _ in true }
        )

        for index in 0...ChatMediaPolicy.maximumThumbnailCount {
            _ = try await loader.thumbnail(for: mediaIdentity(blobID: "tiny-\(index)"))
        }
        #expect(loader.metrics().thumbnailCount == ChatMediaPolicy.maximumThumbnailCount)
        #expect(await counter.count == 65)

        _ = try await loader.thumbnail(for: mediaIdentity(blobID: "tiny-0"))
        #expect(await counter.count == 66)
        #expect(loader.metrics().thumbnailCount == ChatMediaPolicy.maximumThumbnailCount)
    }

    @Test("decoded-byte LRU stays under four MiB for full thumbnail squares")
    func decodedByteBound() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_304).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 512,
            pixelHeight: 512,
            orientation: .up
        )
        let loader = ChatMediaLoader(
            fetch: { _ in .init(data: fixture.encodedData, mimeType: "image/jpeg") },
            admits: { _ in true }
        )

        for index in 0..<32 {
            _ = try await loader.thumbnail(for: mediaIdentity(blobID: "square-\(index)"))
        }
        let metrics = loader.metrics()
        #expect(metrics.decodedThumbnailBytes <= ChatMediaPolicy.maximumDecodedThumbnailBytes)
        #expect(metrics.thumbnailCount <= 28)
    }

    @Test("oversized encoded payloads are rejected before decode or insertion")
    func encodedAdmission() async {
        let loader = ChatMediaLoader(
            fetch: { _ in
                .init(data: Data(count: ChatMediaPolicy.maximumEncodedBytes + 1), mimeType: "image/png")
            },
            admits: { _ in true }
        )

        await #expect(throws: ChatMediaLoadError.encodedPayloadTooLarge) {
            try await loader.thumbnail(for: mediaIdentity(blobID: "oversized"))
        }
        #expect(loader.metrics().thumbnailCount == 0)
    }

    @Test("a failed decode does not poison an exact identity retry")
    func retryAfterDecodeFailure() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_309).generatedImageFixture(
            format: .png,
            pixelWidth: 24,
            pixelHeight: 24,
            orientation: .up
        )
        let fetch = MediaRetryFetch(validPayload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let loader = ChatMediaLoader(
            fetch: { identity in await fetch.fetch(identity) },
            admits: { _ in true }
        )
        let identity = mediaIdentity(blobID: "retry")

        await #expect(throws: ChatMediaLoadError.invalidImage) {
            try await loader.thumbnail(for: identity)
        }
        _ = try await loader.thumbnail(for: identity)
        #expect(await fetch.count == 2)
        #expect(loader.metrics().thumbnailCount == 1)
    }

    @Test("profile and lifecycle identity isolate equal blob IDs across reconnects")
    func identityIsolation() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_305).generatedImageFixture(
            format: .png,
            pixelWidth: 32,
            pixelHeight: 32,
            orientation: .up
        )
        let counter = MediaFetchCounter(payload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let loader = ChatMediaLoader(
            fetch: { identity in await counter.fetch(identity) },
            admits: { _ in true }
        )
        let first = mediaIdentity(profileID: "first", blobID: "same")
        let second = mediaIdentity(profileID: "second", blobID: "same")
        let nextLifecycle = mediaIdentity(
            profileID: "second",
            lifecycleGeneration: 8,
            blobID: "same"
        )

        _ = try await loader.thumbnail(for: first)
        _ = try await loader.thumbnail(for: second)
        _ = try await loader.thumbnail(for: nextLifecycle)
        #expect(await counter.count == 3)
        #expect(loader.metrics().thumbnailCount == 3)
    }

    @Test("cached thumbnail hits revalidate profile and lifecycle admission")
    func cachedThumbnailRevalidatesAdmission() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_306).generatedImageFixture(
            format: .png,
            pixelWidth: 32,
            pixelHeight: 32,
            orientation: .up
        )
        var admitted = true
        let loader = ChatMediaLoader(
            fetch: { _ in .init(data: fixture.encodedData, mimeType: "image/png") },
            admits: { _ in admitted }
        )
        let identity = mediaIdentity(blobID: "cached")
        _ = try await loader.thumbnail(for: identity)
        #expect(loader.metrics().thumbnailCount == 1)

        admitted = false
        await #expect(throws: ChatMediaLoadError.staleIdentity) {
            try await loader.thumbnail(for: identity)
        }
        #expect(loader.metrics().thumbnailCount == 1)
    }

    @Test("stale identity never installs fetched media")
    func staleAdmission() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_306).generatedImageFixture(
            format: .png,
            pixelWidth: 32,
            pixelHeight: 32,
            orientation: .up
        )
        let loader = ChatMediaLoader(
            fetch: { _ in .init(data: fixture.encodedData, mimeType: "image/png") },
            admits: { _ in false }
        )

        await #expect(throws: ChatMediaLoadError.staleIdentity) {
            try await loader.thumbnail(for: mediaIdentity(blobID: "stale"))
        }
        #expect(loader.metrics().thumbnailCount == 0)
    }

    @Test("local composer previews share the bounded media preparation slot")
    func localPreviewPreparation() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_314).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 80,
            pixelHeight: 60,
            orientation: .up
        )
        let image = try #require(UIImage(data: fixture.encodedData))
        let decodeGate = MediaDecodeGate(image: image)
        let fetchGate = MediaFetchGate(payload: .init(data: fixture.encodedData, mimeType: "image/jpeg"))
        let loader = ChatMediaLoader(
            fetch: { identity in try await fetchGate.fetch(identity) },
            fullPreviewDecode: { data in try await decodeGate.decodeFull(data) },
            admits: { _ in true }
        )
        let local = Task { try await loader.prepareLocalFullPreview(fixture.encodedData) }
        await decodeGate.waitForStarts(1)
        let thumbnail = Task { try await loader.thumbnail(for: mediaIdentity(blobID: "after-local")) }
        await loader.hostedWaitForThumbnailFlightCount(1)
        #expect(await fetchGate.startCount == 0)

        local.cancel()
        #expect(await fetchGate.startCount == 0)
        await decodeGate.release()
        await #expect(throws: CancellationError.self) { try await local.value }
        await fetchGate.waitForStarts(1)
        await fetchGate.release()
        _ = try await thumbnail.value
        #expect(loader.metrics().thumbnailCount == 1)
    }

    @Test("one preview lease cannot cancel another owner of the shared flight")
    func previewLeaseCancellation() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_311).generatedImageFixture(
            format: .png,
            pixelWidth: 24,
            pixelHeight: 24,
            orientation: .up
        )
        let decoded = try #require(UIImage(data: fixture.encodedData))
        let counter = MediaFetchCounter(payload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let decodeGate = MediaDecodeGate(image: decoded)
        let loader = ChatMediaLoader(
            fetch: { identity in await counter.fetch(identity) },
            fullPreviewDecode: { data in try await decodeGate.decodeFull(data) },
            admits: { _ in true }
        )
        let identity = mediaIdentity(blobID: "leased-preview")
        let firstLease = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondLease = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let first = Task { try await loader.fullPreview(for: identity, leaseID: firstLease) }
        await decodeGate.waitForStarts(1)
        let second = Task { try await loader.fullPreview(for: identity, leaseID: secondLease) }
        await loader.hostedWaitForPreviewLeaseCount(2)

        loader.cancelFullPreview(for: identity, leaseID: firstLease)
        #expect(loader.metrics().hasFullPreviewFlight)
        await decodeGate.release()
        await #expect(throws: ChatMediaLoadError.staleIdentity) { try await first.value }
        _ = try await second.value
        #expect(await counter.count == 1)
        #expect(!loader.metrics().hasFullPreviewFlight)
    }

    @Test("file preview leases share the exact uncached preview flight")
    func filePreviewLeaseCancellation() async throws {
        let gate = MediaFetchGate(payload: .init(
            data: Data("# Shared preview".utf8),
            mimeType: "text/markdown"
        ))
        let loader = ChatMediaLoader(
            fetch: { identity in try await gate.fetch(identity) },
            admits: { _ in true }
        )
        let identity = mediaIdentity(blobID: "shared-file-preview")
        let firstLease = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let secondLease = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let first = Task { try await loader.filePreviewPayload(for: identity, leaseID: firstLease) }
        await gate.waitForStarts(1)
        let second = Task { try await loader.filePreviewPayload(for: identity, leaseID: secondLease) }
        await loader.hostedWaitForPreviewLeaseCount(2)

        loader.cancelFilePreview(for: identity, leaseID: firstLease)
        #expect(loader.metrics().hasFullPreviewFlight)
        await gate.release()
        await #expect(throws: ChatMediaLoadError.staleIdentity) { try await first.value }
        let payload = try await second.value
        #expect(String(data: payload.data, encoding: .utf8) == "# Shared preview")
        #expect(await gate.startCount == 1)
        #expect(!loader.metrics().hasFullPreviewFlight)
    }

    @Test("image and file previews serialize through one replacement flight and work slot")
    func imageAndFilePreviewOwnership() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_315).generatedImageFixture(
            format: .png,
            pixelWidth: 24,
            pixelHeight: 24,
            orientation: .up
        )
        let image = try #require(UIImage(data: fixture.encodedData))
        let decodeGate = MediaDecodeGate(image: image)
        let fileGate = MediaFetchGate(payload: .init(
            data: Data("serialized file".utf8),
            mimeType: "text/plain"
        ))
        let loader = ChatMediaLoader(
            fetch: { identity in
                if identity.blobID == "image-preview" {
                    return .init(data: fixture.encodedData, mimeType: "image/png")
                }
                return try await fileGate.fetch(identity)
            },
            fullPreviewDecode: { data in try await decodeGate.decodeFull(data) },
            admits: { _ in true }
        )
        let imageFlight = Task {
            try await loader.fullPreview(
                for: mediaIdentity(blobID: "image-preview"),
                leaseID: UUID()
            )
        }
        await decodeGate.waitForStarts(1)
        let fileFlight = Task {
            try await loader.filePreviewPayload(
                for: mediaIdentity(blobID: "file-preview"),
                leaseID: UUID()
            )
        }
        await loader.hostedWaitForFilePreviewFlight()
        #expect(await fileGate.startCount == 0)
        await decodeGate.release()
        await fileGate.waitForStarts(1)
        await fileGate.release()
        await #expect(throws: CancellationError.self) { try await imageFlight.value }
        let payload = try await fileFlight.value
        #expect(String(data: payload.data, encoding: .utf8) == "serialized file")
        #expect(!loader.metrics().hasFullPreviewFlight)
    }

    @Test("file preview admission, encoded bounds, and removal share image preview ownership")
    func filePreviewAdmissionAndRetirement() async throws {
        var admitted = false
        let staleCounter = MediaFetchCounter(payload: .init(
            data: Data("stale".utf8),
            mimeType: "text/plain"
        ))
        let staleLoader = ChatMediaLoader(
            fetch: { identity in await staleCounter.fetch(identity) },
            admits: { _ in admitted }
        )
        await #expect(throws: ChatMediaLoadError.staleIdentity) {
            try await staleLoader.filePreviewPayload(
                for: mediaIdentity(blobID: "stale-file"),
                leaseID: UUID()
            )
        }
        #expect(await staleCounter.count == 0)

        admitted = true
        let oversizedLoader = ChatMediaLoader(
            fetch: { _ in .init(
                data: Data(count: ChatMediaPolicy.maximumEncodedBytes + 1),
                mimeType: "text/plain"
            ) },
            admits: { _ in true }
        )
        await #expect(throws: ChatMediaLoadError.encodedPayloadTooLarge) {
            try await oversizedLoader.filePreviewPayload(
                for: mediaIdentity(blobID: "oversized-file"),
                leaseID: UUID()
            )
        }

        let gate = MediaFetchGate(payload: .init(
            data: Data("retired".utf8),
            mimeType: "text/plain"
        ))
        let loader = ChatMediaLoader(
            fetch: { identity in try await gate.fetch(identity) },
            admits: { _ in true }
        )
        let flight = Task {
            try await loader.filePreviewPayload(
                for: mediaIdentity(blobID: "retired-file"),
                leaseID: UUID()
            )
        }
        await gate.waitForStarts(1)
        #expect(loader.metrics().hasFullPreviewFlight)
        loader.removeAll()
        #expect(!loader.metrics().hasFullPreviewFlight)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await flight.value }
    }

    @Test("full previews are single-flight but never enter the thumbnail cache")
    func fullPreviewLifetime() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_307).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 80,
            pixelHeight: 60,
            orientation: .up
        )
        let counter = MediaFetchCounter(payload: .init(data: fixture.encodedData, mimeType: "image/jpeg"))
        let loader = ChatMediaLoader(
            fetch: { identity in await counter.fetch(identity) },
            admits: { _ in true }
        )
        let identity = mediaIdentity(blobID: "preview")

        _ = try await loader.fullPreview(
            for: identity,
            leaseID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        _ = try await loader.fullPreview(
            for: identity,
            leaseID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        #expect(await counter.count == 2)
        #expect(loader.metrics().thumbnailCount == 0)
        #expect(!loader.metrics().hasFullPreviewFlight)
    }

    @Test("memory pressure clears cached thumbnails and cancels owned flights")
    func memoryPressure() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_308).generatedImageFixture(
            format: .png,
            pixelWidth: 32,
            pixelHeight: 32,
            orientation: .up
        )
        let loader = ChatMediaLoader(
            fetch: { _ in .init(data: fixture.encodedData, mimeType: "image/png") },
            admits: { _ in true }
        )
        _ = try await loader.thumbnail(for: mediaIdentity(blobID: "cached"))
        #expect(loader.metrics().thumbnailCount == 1)

        loader.removeAll()
        #expect(loader.metrics() == ChatMediaMetrics(
            thumbnailCount: 0,
            decodedThumbnailBytes: 0,
            thumbnailFlights: 0,
            hasFullPreviewFlight: false
        ))

        let gate = MediaFetchGate(payload: .init(data: fixture.encodedData, mimeType: "image/png"))
        let flightLoader = ChatMediaLoader(
            fetch: { identity in try await gate.fetch(identity) },
            admits: { _ in true }
        )
        let flight = Task { try await flightLoader.thumbnail(for: mediaIdentity(blobID: "flight")) }
        await gate.waitForStarts(1)
        #expect(flightLoader.metrics().thumbnailFlights == 1)
        flightLoader.removeAll()
        #expect(flightLoader.metrics().thumbnailFlights == 0)
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await flight.value
        }

        let decoded = try #require(UIImage(data: fixture.encodedData))
        let decodeGate = MediaDecodeGate(image: decoded)
        let decodeLoader = ChatMediaLoader(
            fetch: { _ in .init(data: fixture.encodedData, mimeType: "image/png") },
            thumbnailDecode: { data in try await decodeGate.decode(data) },
            admits: { _ in true }
        )
        let decodeFlight = Task {
            try await decodeLoader.thumbnail(for: mediaIdentity(blobID: "decoding"))
        }
        await decodeGate.waitForStarts(1)
        #expect(decodeLoader.metrics().thumbnailFlights == 1)
        decodeLoader.removeAll()
        await decodeGate.release()
        await #expect(throws: CancellationError.self) {
            try await decodeFlight.value
        }
        #expect(decodeLoader.metrics().thumbnailCount == 0)
    }

    @Test("the app-lifetime observer clears media on a posted memory warning")
    func appLifetimeMemoryWarning() async throws {
        let fixture = try SessionScenarioBuilder(seed: 6_312).generatedImageFixture(
            format: .png,
            pixelWidth: 24,
            pixelHeight: 24,
            orientation: .up
        )
        let loader = ChatMediaLoader(
            fetch: { _ in .init(data: fixture.encodedData, mimeType: "image/png") },
            admits: { _ in true }
        )
        _ = try await loader.thumbnail(for: mediaIdentity(blobID: "warning"))
        #expect(loader.metrics().thumbnailCount == 1)
        let ready = MediaSignal()
        let handled = MediaSignal()
        let observer = ChatMediaMemoryPressureObserver(
            loader: loader,
            hostedOnReady: { await ready.signal() },
            hostedOnHandled: { await handled.signal() }
        )
        await ready.wait()

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await handled.wait()
        #expect(loader.metrics().thumbnailCount == 0)
        withExtendedLifetime(observer) {}
    }

    private func mediaIdentity(
        profileID: String = "profile",
        lifecycleGeneration: Int = 7,
        blobID: String
    ) -> ChatMediaIdentity {
        ChatMediaIdentity(
            profileID: profileID,
            lifecycleGeneration: lifecycleGeneration,
            blobID: blobID
        )
    }
}

private actor MediaFetchCounter {
    let payload: ChatMediaPayload
    private(set) var count = 0

    init(payload: ChatMediaPayload) { self.payload = payload }

    func fetch(_ identity: ChatMediaIdentity) -> ChatMediaPayload {
        _ = identity
        count += 1
        return payload
    }
}

private actor MediaSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        isSignaled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor MediaDecodeGate {
    let image: UIImage
    private var startCount = 0
    private var released = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(image: UIImage) { self.image = image }

    func decode(_ data: Data) async throws -> (UIImage, Int) {
        _ = data
        startCount += 1
        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if !released {
            await withCheckedContinuation { decodeWaiters.append($0) }
        }
        return (image, image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1)
    }

    var count: Int { startCount }

    func decodeFull(_ data: Data) async throws -> UIImage {
        let value = try await decode(data)
        return value.0
    }

    func waitForStarts(_ count: Int) async {
        if startCount >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        let waiters = decodeWaiters
        decodeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MediaRetryFetch {
    let validPayload: ChatMediaPayload
    private(set) var count = 0

    init(validPayload: ChatMediaPayload) { self.validPayload = validPayload }

    func fetch(_ identity: ChatMediaIdentity) -> ChatMediaPayload {
        _ = identity
        count += 1
        if count == 1 {
            return ChatMediaPayload(data: Data("not-an-image".utf8), mimeType: "image/png")
        }
        return validPayload
    }
}

private actor MediaFetchGate {
    let payload: ChatMediaPayload
    private(set) var startCount = 0
    private var released = false
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(payload: ChatMediaPayload) { self.payload = payload }

    func fetch(_ identity: ChatMediaIdentity) async throws -> ChatMediaPayload {
        _ = identity
        startCount += 1
        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if !released {
            await withCheckedContinuation { fetchWaiters.append($0) }
        }
        try Task.checkCancellation()
        return payload
    }

    func waitForStarts(_ count: Int) async {
        if startCount >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release() {
        released = true
        let waiters = fetchWaiters
        fetchWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

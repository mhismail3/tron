import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One app-wide ImageIO slot, including retired view generations. Cancellation
/// cannot interrupt native decoding already in progress; replacements drop the
/// candidate (and poll the latest frame later) rather than queue or overlap it.
actor BrowserLiveImagePreparation {
    static let shared = BrowserLiveImagePreparation()
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

extension GatewayClient {
    /// A disposable viewer owns its original request/credential and transport.
    /// Cleanup must not consult the subsequently selected Gateway profile.
    actor BrowserLiveLease {
        let leaseId: String
        let descriptor: BrowserLiveViewDescriptor
        private let request: URLRequest
        private let transport: BoundedHTTPDataTransport
        private var closeTask: Task<Void, Never>?

        struct Wire: Decodable {
            let leaseId: String
            let descriptor: BrowserLiveViewDescriptor
        }

        init(wire: Wire, request: URLRequest, transport: BoundedHTTPDataTransport) throws {
            guard UUID(uuidString: wire.leaseId) != nil, wire.descriptor.isValid else { throw BrowserLiveError.invalidResponse }
            leaseId = wire.leaseId
            descriptor = wire.descriptor
            var bound = request
            bound.httpBody = nil
            bound.setValue(nil, forHTTPHeaderField: "Content-Length")
            bound.setValue(nil, forHTTPHeaderField: "Content-Type")
            bound.setValue(wire.leaseId, forHTTPHeaderField: "X-Tron-Live-Lease")
            bound.setValue(wire.descriptor.generation, forHTTPHeaderField: "X-Tron-Live-Generation")
            self.request = bound
            self.transport = transport
        }

        func frame(after sequence: Int) async throws -> BrowserLiveUpdate {
            try Task.checkCancellation()
            guard closeTask == nil else { throw CancellationError() }
            var request = request
            request.url = request.url?.appendingPathComponent("frame")
            request.httpMethod = "GET"
            request.setValue(String(sequence), forHTTPHeaderField: "X-Tron-Live-After")
            let (data, response) = try await transport.data(for: request, maximumBytes: BrowserLiveFrame.maximumEncodedBytes)
            try Task.checkCancellation()
            guard closeTask == nil else { throw CancellationError() }
            guard response.url == request.url else { throw BrowserLiveError.invalidResponse }
            if response.statusCode == 204 {
                switch response.value(forHTTPHeaderField: "X-Tron-Live-State") {
                case "waiting": return .waiting
                case "unchanged": return .unchanged
                default: throw BrowserLiveError.ended
                }
            }
            guard response.statusCode == 200 else { throw BrowserLiveError.ended }
            return .frame(try BrowserLiveFrame(data: data, response: response))
        }

        /// Join cancellation-independent teardown. The caller may already be
        /// cancelled; cancelling DELETE with it would abandon the remote lease.
        func close() async {
            if let closeTask { await closeTask.value; return }
            var closing = request
            closing.httpMethod = "DELETE"
            closing.timeoutInterval = 5
            let transport = transport
            let closeRequest = closing
            let cleanup = Task.detached {
                _ = try? await transport.data(for: closeRequest, maximumBytes: 8_192)
            }
            closeTask = cleanup
            await cleanup.value
        }
    }

    enum BrowserLiveError: Error { case ended, invalidResponse }
    enum BrowserLiveUpdate: Sendable { case waiting, unchanged, frame(BrowserLiveFrame) }

    struct BrowserLiveFrame: Sendable {
        static let maximumEncodedBytes = 2 * 1_024 * 1_024
        static let maximumPixels = 4_000_000
        static let maximumEdge = 2_560
        static let maximumDecodedBytes = 16_000_000
        let data: Data
        let width: Int
        let height: Int
        let sequence: Int

        init(data: Data, response: HTTPURLResponse) throws {
            guard !data.isEmpty, data.count <= Self.maximumEncodedBytes,
                  response.value(forHTTPHeaderField: "Content-Type")?.lowercased() == "image/jpeg",
                  let width = Int(response.value(forHTTPHeaderField: "X-Tron-Live-Width") ?? ""),
                  let height = Int(response.value(forHTTPHeaderField: "X-Tron-Live-Height") ?? ""),
                  let sequence = Int(response.value(forHTTPHeaderField: "X-Tron-Live-Sequence") ?? ""),
                  width > 0, width <= Self.maximumEdge, height > 0, height <= Self.maximumEdge,
                  width * height <= Self.maximumPixels, sequence > 0, sequence <= 9_007_199_254_740_991 else {
                throw BrowserLiveError.invalidResponse
            }
            self.data = data
            self.width = width
            self.height = height
            self.sequence = sequence
        }

        func decode() async throws -> UIImage? {
            try await BrowserLiveImagePreparation.shared.prepare { try self.decodeImage() }
        }

        private func decodeImage() throws -> UIImage {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else {
                throw BrowserLiveError.invalidResponse
            }
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumEdge,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary), image.width == width, image.height == height,
                  ChatMediaPolicy.decodedByteCount(bytesPerRow: image.bytesPerRow, height: image.height,
                    maximum: Self.maximumDecodedBytes) != nil else { throw BrowserLiveError.invalidResponse }
            try Task.checkCancellation()
            return UIImage(cgImage: image)
        }
    }
}

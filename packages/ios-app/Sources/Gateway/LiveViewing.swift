import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One app-wide ImageIO slot, including retired view generations. Cancellation
/// cannot interrupt native decoding already in progress; replacements drop the
/// candidate (and poll the latest frame later) rather than queue or overlap it.
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

extension GatewayClient {
    /// A disposable viewer owns its original request/credential and transport.
    /// Cleanup must not consult the subsequently selected Gateway profile.
    actor LiveLease {
        let leaseId: String
        let descriptor: LiveViewDescriptor
        private let request: URLRequest
        private let transport: BoundedHTTPDataTransport
        private var closeTask: Task<Void, Never>?

        struct Wire: Decodable {
            let leaseId: String
            let descriptor: LiveViewDescriptor
        }

        init(wire: Wire, request: URLRequest, transport: BoundedHTTPDataTransport) throws {
            guard UUID(uuidString: wire.leaseId) != nil, wire.descriptor.isValid else { throw LiveError.invalidResponse }
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

        func frame(after sequence: Int) async throws -> LiveUpdate {
            try Task.checkCancellation()
            guard closeTask == nil else { throw CancellationError() }
            var request = request
            request.url = request.url?.appendingPathComponent("frame")
            request.httpMethod = "GET"
            request.timeoutInterval = 3 // Cached-frame reads; keep the retry budget below the lease idle bound.
            request.setValue(String(sequence), forHTTPHeaderField: "X-Tron-Live-After")
            // Only idempotent frame GETs retry, on this exact lease. Admission
            // POST, native start, source loss and malformed frames never replay.
            for attempt in 0..<3 {
                try Task.checkCancellation()
                guard closeTask == nil else { throw CancellationError() }
                do {
                    let (data, response) = try await transport.data(for: request, maximumBytes: LiveFrame.maximumEncodedBytes)
                    try Task.checkCancellation()
                    guard closeTask == nil else { throw CancellationError() }
                    guard response.url == request.url else { throw LiveError.invalidResponse }
                    if response.statusCode == 204 {
                        switch response.value(forHTTPHeaderField: "X-Tron-Live-State") {
                        case "waiting": return .waiting
                        case "unchanged": return .unchanged
                        default: throw LiveError.ended
                        }
                    }
                    guard response.statusCode == 200 else { throw LiveError.response(data, status: response.statusCode) }
                    return .frame(try LiveFrame(data: data, response: response))
                } catch {
                    try Task.checkCancellation()
                    guard closeTask == nil else { throw CancellationError() }
                    let failure = LiveError.classify(error)
                    guard attempt < 2, failure.isTransient else { throw failure }
                    try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                }
            }
            throw LiveError.connectionInterrupted
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

    enum LiveError: Error, Equatable, Sendable {
        case ended, invalidResponse, permissionRequired, sourceUnavailable, captureBusy
        case captureUnavailable, firstFrameTimeout, temporarilyUnavailable, connectionInterrupted

        var isTransient: Bool { self == .temporarilyUnavailable || self == .connectionInterrupted }
        var message: String {
            switch self {
            case .ended: "This live view has ended. Select the source again to view it."
            case .invalidResponse: "The live preview received an invalid frame or response."
            case .permissionRequired: "Screen Recording permission is required. Check Tron’s Permissions on your Mac, then select the source again."
            case .sourceUnavailable: "The selected source is unavailable. Make sure the window or display is available, then select it again."
            case .captureBusy: "Native capture is busy or still stopping. Close other live views before trying again."
            case .captureUnavailable: "The Mac could not provide this live preview. Check Tron on your Mac before selecting the source again."
            case .firstFrameTimeout: "No live frames arrived. Check for a screen-capture dialog on your Mac, then select the source again."
            case .temporarilyUnavailable, .connectionInterrupted: "The live preview connection was interrupted. Reopen the view after the Gateway reconnects."
            }
        }

        static func classify(_ error: any Error) -> Self {
            if let failure = error as? Self { return failure }
            if let error = error as? URLError,
               [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
                return .connectionInterrupted
            }
            return .invalidResponse
        }

        private struct Envelope: Decodable {
            struct Body: Decodable {
                struct Details: Decodable { let liveViewFailure: String? }
                let code: String?
                let retryable: Bool?
                let details: Details?
            }
            let error: Body
        }
        static func response(_ data: Data, status: Int) -> Self {
            // Never render server exception messages/details: only this finite
            // classification is allowed to become user-facing text.
            guard data.count <= 8_192 else { return .invalidResponse }
            let error = try? JSONDecoder().decode(Envelope.self, from: data).error
            switch error?.details?.liveViewFailure {
            case "permission_required": return .permissionRequired
            case "source_unavailable": return .sourceUnavailable
            case "capture_busy": return .captureBusy
            case "capture_unavailable": return .captureUnavailable
            case "first_frame_timeout": return .firstFrameTimeout
            default: break
            }
            if error?.retryable == true, ["busy", "internal"].contains(error?.code ?? ""), [429, 500, 502, 503, 504].contains(status) { return .temporarilyUnavailable }
            switch status {
            case 401, 403, 404: return .ended
            case 409, 429: return .captureBusy
            default: return .captureUnavailable
            }
        }
    }
    enum LiveUpdate: Sendable { case waiting, unchanged, frame(LiveFrame) }

    struct LiveFrame: Sendable {
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
                throw LiveError.invalidResponse
            }
            self.data = data
            self.width = width
            self.height = height
            self.sequence = sequence
        }

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
                throw LiveError.invalidResponse
            }
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumEdge,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary), image.width == width, image.height == height,
                  ChatMediaPolicy.decodedByteCount(bytesPerRow: image.bytesPerRow, height: image.height,
                    maximum: Self.maximumDecodedBytes) != nil else { throw LiveError.invalidResponse }
            try Task.checkCancellation()
            return UIImage(cgImage: image)
        }
    }
}

import AVFoundation
import Foundation
import Observation
import TronMobileCore

/// One presentation owns its player and staged file. Retiring or superseding a
/// request invalidates both download completions and queued AVFoundation callbacks.
@MainActor
@Observable
final class DisplayVideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var failed = false
    private(set) var requestID = UUID().uuidString
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    func prepare(mimeType: String, load: () async throws -> URL) async {
        guard !Task.isCancelled else { return }
        stop()
        let request = requestID
        do {
            let url = try await load()
            guard !Task.isCancelled, requestID == request else {
                BoundedHTTPFileStaging.shared.discard(url)
                return
            }
            fileURL = url
            // Staging deliberately has opaque, extensionless names. Carry the
            // Gateway's admitted media type into AVFoundation, not the filename.
            let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mimeType])
            let item = AVPlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status.rawValue
                let error = item.error as NSError?
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == request else { return }
                    if status == AVPlayerItem.Status.failed.rawValue {
                        self.fail(stage: "player", error: error, status: status, request: request)
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, requestID == request, !(error is CancellationError) else { return }
            fail(stage: "download", error: error as NSError, status: nil, request: request)
        }
    }

    func stop() {
        requestID = UUID().uuidString
        releaseMedia()
        failed = false
    }

    private func releaseMedia() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let fileURL {
            BoundedHTTPFileStaging.shared.discard(fileURL)
            self.fileURL = nil
        }
    }

    private func fail(stage: String, error: NSError?, status: Int?, request: String) {
        // The first observed failure retires the item before its file. No retry
        // or parallel player survives the presentation's unavailable state.
        guard !failed else { return }
        releaseMedia()
        failed = true
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        let details = "stage=\(stage) status=\(status.map(String.init) ?? "none") \(Self.diagnostic(error)) underlying=\(Self.diagnostic(underlying))"
        Task {
            await AppLog.shared.recordCausal(
                name: "display.media", outcome: "failure", requestID: request, details: details
            )
        }
    }

    private static func diagnostic(_ error: NSError?) -> String {
        guard let error else { return "domain=none code=none" }
        let domains = [AVFoundationErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain, NSCocoaErrorDomain]
        let domain = domains.contains(error.domain) ? error.domain : "other"
        // Error descriptions/userInfo can contain authenticated URLs and local
        // paths. Only known domains and numeric codes belong in exported logs.
        return "domain=\(domain) code=\(error.code)"
    }
}

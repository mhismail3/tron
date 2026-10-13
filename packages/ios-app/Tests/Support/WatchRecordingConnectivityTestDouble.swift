#if HOSTED_TEST
import Foundation

@MainActor
final class WatchRecordingConnectivity {
    static let shared = WatchRecordingConnectivity()
    var configuredDestination: WatchRecordingDestinationV1?

    func enqueue(_ manifest: WatchRecordingManifest, store: WatchRecordingStore) async {}
}
#endif

import SwiftUI

/// Transient compaction detail projected from the existing durable
/// `compact.boundary` event and rendered by the shared native UI runtime.
struct CompactionDetailSheet: View {
    @Environment(\.dependencies) private var dependencies
    let sessionId: String
    let eventId: String

    var body: some View {
        NativeUISurfaceView(
            repository: dependencies.nativeUIRepository,
            request: NativeUISurfaceRequest(
                definitionId: "session.compaction_detail",
                surfaceId: surfaceId,
                sessionId: sessionId,
                eventId: eventId
            ),
            cacheNamespace: cacheNamespace,
            dismissTransientOnDisappear: true,
            presentsAsSheet: true
        )
        .tint(.cyan)
    }

    private var surfaceId: String {
        "session.compaction_detail:\(sessionId):\(eventId)"
    }

    private var cacheNamespace: String {
        dependencies.pairedServerStore.activeServer?.id ?? "unpaired"
    }
}

import Foundation
import TronMobileCore

struct SessionPresentationIdentity: Hashable, Sendable {
    let sessionID: String
    let generation: Int
}

enum SessionSnapshotInstallationMode { case freshPresentation, reconnect }
enum SessionEditorAction: String, Hashable, Sendable { case set, paste, native }

enum SessionTranscriptLoadState: Equatable, Sendable {
    case idle
    case loading
    case failed(String)
}

enum SessionTranscriptLoadResult: Equatable, Sendable {
    case installed
    case unavailable
    case stale
    case failed
}

struct MountedTranscriptCoverage: Equatable, Sendable {
    let sessionID: String
    let runtimeGeneration: String
    let leafEntryID: String?
    let total: Int
    let start: Int
    let end: Int
    let structureRevision: Int
}

/// The mounted transcript owns only the retained prefix. The Gateway tail
/// remains in SessionSnapshot and is never copied into this window.
struct MountedTranscriptWindow: Equatable, Sendable {
    let coverage: MountedTranscriptCoverage
    let prefixItems: [TranscriptItem]
}

struct GatewaySessionOpenResponse: Decodable {
    let session: SessionSnapshot
    let syncToken: String
    let subscriptionToken: String
    let completionRevision: Int

    private enum CodingKeys: String, CodingKey { case session, syncToken, subscriptionToken, completionRevision }
    private enum SessionDiagnosticKeys: String, CodingKey {
        case transcript, extensionPresentation, extensionActivities, processOverview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionSnapshot.self, forKey: .session)
        func invalidSessionProjection(_ key: SessionDiagnosticKeys, _ description: String) -> DecodingError {
            .dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.session, key],
                debugDescription: description
            ))
        }
        guard SessionSnapshotTranscriptAdmissionPolicy.admit(session) else {
            throw invalidSessionProjection(.transcript, "Invalid transcript snapshot")
        }
        guard ExtensionPresentationPolicy.admit(session.extensionPresentation) else {
            throw invalidSessionProjection(.extensionPresentation, "Invalid extension presentation snapshot")
        }
        guard ExtensionActivityAdmissionPolicy.admitsSnapshotFacts(session) else {
            throw invalidSessionProjection(.extensionActivities, "Invalid extension activity snapshot")
        }
        guard SessionProcessAdmissionPolicy.admitsSnapshotFacts(session) else {
            throw invalidSessionProjection(.processOverview, "Invalid process activity snapshot")
        }
        let decodedSyncToken = try container.decode(String.self, forKey: .syncToken)
        let decodedSubscriptionToken = try container.decode(String.self, forKey: .subscriptionToken)
        let decodedCompletionRevision = try container.decodeIfPresent(Int.self, forKey: .completionRevision) ?? 0
        guard GatewayTokenAdmissionPolicy.admit(decodedSyncToken) else {
            throw DecodingError.dataCorruptedError(forKey: .syncToken, in: container, debugDescription: "Invalid sync token")
        }
        guard GatewayTokenAdmissionPolicy.admit(decodedSubscriptionToken) else {
            throw DecodingError.dataCorruptedError(forKey: .subscriptionToken, in: container, debugDescription: "Invalid subscription token")
        }
        syncToken = decodedSyncToken
        guard decodedCompletionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .completionRevision, in: container, debugDescription: "Invalid completion revision")
        }
        subscriptionToken = decodedSubscriptionToken
        completionRevision = decodedCompletionRevision
    }
}

@MainActor
protocol SessionPresentationStoreDelegate: AnyObject {
    func sessionPresentationStoreDidRequestCatalogRefresh()
    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationIdentity,
        action: SessionEditorAction,
        text: String,
        fullText: String,
        revision: Int,
        operationID: String?
    )
    func sessionPresentationStoreDidOpen(_ target: SessionPresentationIdentity)
    func sessionPresentationStoreDidBecomeVisible(_ target: SessionPresentationIdentity, at date: Date)
    func sessionPresentationStoreDidPublishSnapshot(
        _ snapshot: SessionSnapshot,
        target: SessionPresentationIdentity
    )
    func sessionPresentationStoreDidFailOperation(
        operationID: String,
        target: SessionPresentationIdentity
    )
    func sessionPresentationStorePostNotice(
        _ message: String,
        replacing key: InAppNoticeKey?,
        role: InAppNoticeCenter.Role,
        scope: InAppNoticeScope?
    )
    func sessionPresentationStoreRemoveNotice(_ key: InAppNoticeKey, scope: InAppNoticeScope?)
    func sessionPresentationStoreRetireNoticeScope(_ scope: InAppNoticeScope)
    func sessionPresentationStoreSurface(_ error: Error)
    func sessionPresentationStoreMeasuredEventWork(_ phase: GatewayEventConsumerPhase, duration: Duration)
}

extension SessionPresentationStoreDelegate {
    func sessionPresentationStoreDidFailOperation(
        operationID: String,
        target: SessionPresentationIdentity
    ) {}
}

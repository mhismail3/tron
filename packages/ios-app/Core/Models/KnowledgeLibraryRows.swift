import Foundation

// Library row projections. A catalogue row and its detail header need a title,
// a link, a bounded preview, and the generated summary — never the saved text,
// raw objects, or provider payload the full record carries. `projection:
// "sourceRow"` asks the Gateway for exactly that, so opening the Library no
// longer transfers a page of evidence the row cannot show.

package enum KnowledgeRowProjection: String, Encodable, Sendable { case sourceRow }

package struct KnowledgeSourceRow: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package let revisionId: String
    package let scope: KnowledgeScope
    package let createdAt: String
    package let updatedAt: String
    package let title: String
    /// Canonical captured URI, after any redirect the capture resolved.
    package let uri: String?
    /// The link the saved item asked for, when it differs from `uri`; the
    /// Gateway applies the same provenance rule the detail used locally.
    package let originalUri: String?
    package let mediaType: String?
    package let captureDisposition: KnowledgeCaptureDisposition
    /// Current admission, as the Gateway's visibility filters see it.
    package let admission: KnowledgeSourceAdmission?
    package let sourceSavedAt: String?
    package let sourcePublishedAt: String?
    package let ageBasis: KnowledgeSourceAgeBasis
    package let ageDays: Int
    package let freshness: KnowledgeSourceFreshness
    package let verdict: KnowledgeSourceVerdict?
    package let supersededBy: String?
    package let hasTake: Bool
    package let tagsStale: Bool
    package let tags: [KnowledgeTagLabel]?
    package let preview: KnowledgeObjectRef?
    /// The current generated summary only, when its evidence digest still
    /// matches the saved text. Already truncated by the Gateway.
    package let summary: String?
}

package struct KnowledgeSourceRowPage: Codable, Hashable, Sendable {
    package let rows: [KnowledgeSourceRow]
    package let nextCursor: String?
    package let stateRevision: Int

    package init(rows: [KnowledgeSourceRow], nextCursor: String?, stateRevision: Int) {
        self.rows = rows; self.nextCursor = nextCursor; self.stateRevision = stateRevision
    }
}

package struct KnowledgeSourceRowListRequest: Encodable, Sendable {
    let kind: KnowledgeRecordKind
    let scope: KnowledgeScope?
    let includeArchived: Bool?
    let includePending: Bool?
    let sourceAdmission: KnowledgeSourceAdmission?
    let cursor: String?
    let ids: [String]?
    let projection: KnowledgeRowProjection
    let limit: Int

    package init(kind: KnowledgeRecordKind, scope: KnowledgeScope?, includeArchived: Bool?, includePending: Bool?, sourceAdmission: KnowledgeSourceAdmission?, cursor: String?, ids: [String]?, limit: Int) {
        self.kind = kind; self.scope = scope; self.includeArchived = includeArchived; self.includePending = includePending
        self.sourceAdmission = sourceAdmission; self.cursor = cursor; self.ids = ids; self.projection = .sourceRow; self.limit = limit
    }
}

package struct KnowledgeSourceRowSearchRequest: Encodable, Sendable {
    let query: String
    let kind: KnowledgeRecordKind
    let scope: KnowledgeScope?
    let includeArchived: Bool?
    let includePending: Bool?
    let sourceAdmission: KnowledgeSourceAdmission?
    let cursor: String?
    let projection: KnowledgeRowProjection
    let limit: Int

    package init(query: String, kind: KnowledgeRecordKind, scope: KnowledgeScope?, includeArchived: Bool?, includePending: Bool?, sourceAdmission: KnowledgeSourceAdmission?, cursor: String?, limit: Int) {
        self.query = query; self.kind = kind; self.scope = scope; self.includeArchived = includeArchived; self.includePending = includePending
        self.sourceAdmission = sourceAdmission; self.cursor = cursor; self.projection = .sourceRow; self.limit = limit
    }
}

package enum KnowledgePreviewLimits {
    package static let maximumBytes = 512_000
    package static let maximumBatchItems = 16
    /// The whole batch must stay well inside one RPC envelope.
    package static let maximumBatchBytes = 4_000_000
}

/// One preview read's exact authority: the record revision that owns the object.
package struct KnowledgePreviewRequest: Hashable, Sendable {
    package let recordID: String
    package let revisionID: String
    package let reference: KnowledgeObjectRef

    package init(recordID: String, revisionID: String, reference: KnowledgeObjectRef) {
        self.recordID = recordID; self.revisionID = revisionID; self.reference = reference
    }

    package var hash: String { reference.hash }
}

extension KnowledgeSourceRow {
    /// The preview read for this exact revision. A reference outside the
    /// readable bound is never fetched; the row presents its letters instead
    /// and claims no image.
    package var previewRequest: KnowledgePreviewRequest? {
        guard let preview, preview.bytes > 0, preview.bytes <= KnowledgePreviewLimits.maximumBytes,
              !preview.hash.isEmpty, !preview.mediaType.isEmpty else { return nil }
        return KnowledgePreviewRequest(recordID: id, revisionID: revisionId, reference: preview)
    }
}

package struct KnowledgePreviewBatchRequest: Encodable, Sendable {
    package struct Item: Encodable, Sendable {
        let recordId: String
        let revisionId: String
        let hash: String
        let mediaType: String
        let bytes: Int
    }

    let items: [Item]
    let includeArchived: Bool?

    package init(requests: [KnowledgePreviewRequest], includeArchived: Bool?) {
        items = requests.map { Item(recordId: $0.recordID, revisionId: $0.revisionID, hash: $0.reference.hash, mediaType: $0.reference.mediaType, bytes: $0.reference.bytes) }
        self.includeArchived = includeArchived
    }
}

package struct KnowledgePreviewBatchItem: Codable, Hashable, Sendable {
    package let recordId: String
    package let hash: String
    package let base64: String?
    /// Why no bytes were returned: `forbidden`, `missing`, or `too-large`.
    package let unavailable: String?

    package init(recordId: String, hash: String, base64: String?, unavailable: String?) {
        self.recordId = recordId; self.hash = hash; self.base64 = base64; self.unavailable = unavailable
    }
}

package struct KnowledgePreviewBatchResponse: Codable, Hashable, Sendable {
    package let items: [KnowledgePreviewBatchItem]

    package init(items: [KnowledgePreviewBatchItem]) { self.items = items }
}

/// Verified bytes and unavailable reasons from one preview batch. Bytes were
/// hash- and length-checked against the exact request that asked for them.
package struct KnowledgePreviewBatchResult: Sendable {
    package let images: [String: Data]
    package let unavailableHashes: Set<String>

    package init(images: [String: Data], unavailableHashes: Set<String>) {
        self.images = images; self.unavailableHashes = unavailableHashes
    }
}

package enum KnowledgeSourceRowPresentationPolicy {
    package static func originalURL(_ row: KnowledgeSourceRow) -> URL? {
        KnowledgeSourcePresentationPolicy.safeURL(row.originalUri) ?? KnowledgeSourcePresentationPolicy.safeURL(row.uri)
    }

    package static func domain(_ row: KnowledgeSourceRow) -> String? {
        KnowledgeSourcePresentationPolicy.domain(row.uri)
    }

    package static func sourceType(_ row: KnowledgeSourceRow) -> String? {
        KnowledgeSourcePresentationPolicy.sourceType(uri: row.uri, mediaType: row.mediaType)
    }

    /// One compact catalogue line: where the entry lives and what it is.
    package static func subtitle(_ row: KnowledgeSourceRow) -> String {
        KnowledgeSourcePresentationPolicy.subtitle(uri: row.uri, mediaType: row.mediaType)
    }

    package static func thumbnailLetters(_ row: KnowledgeSourceRow) -> String {
        KnowledgeSourcePresentationPolicy.thumbnailLetters(uri: row.uri, title: row.title)
    }
}

package enum KnowledgeLibraryCapability {
    /// Rows, batch previews, and search pagination ship together; a Gateway
    /// without this cannot serve the Library's Sources view.
    package static let libraryRows = "knowledge-library-rows.v1"
}

/// The Library's search behavior. Two characters is the shortest query worth a
/// round trip, and the debounce keeps a typed word to one request.
package enum KnowledgeSearchPolicy {
    package static let minimumQueryLength = 2
    package static let debounce: Duration = .milliseconds(300)

    package static func admitsQuery(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQueryLength
    }

    /// A query too short to search is presented as no query at all, not as an
    /// empty result.
    package static func effectiveQuery(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return admitsQuery(trimmed) ? trimmed : ""
    }
}

/// Change-event gating. A dashboard page older than the Gateway's committed
/// revision must refresh; an event at or below its own revision is already
/// reflected and must not disturb scroll or the page.
package enum KnowledgeChangeGating {
    package static func requiresRefresh(eventRevision: Int, pageRevision: Int) -> Bool {
        eventRevision > pageRevision
    }

    /// More changed records than the event can carry means the client cannot
    /// patch individual rows and refreshes the first page instead.
    package static let maximumRecordIDs = 64
}

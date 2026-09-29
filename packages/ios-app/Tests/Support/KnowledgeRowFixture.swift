import Foundation
@testable import TronMobileCore

/// Gateway-shaped wire fixtures for the Library's row projection. Tests decode
/// these exact shapes instead of constructing rows in code, so a field the
/// Gateway renames or drops fails here rather than in the Library.
enum KnowledgeRowFixture {
    static func rowJSON(
        id: String = "row-1",
        revisionId: String = "revision-1",
        scope: String = "research",
        title: String = "An entry",
        uri: String? = "https://example.test/article",
        originalUri: String? = nil,
        mediaType: String? = "text/html",
        captureDisposition: String = "complete",
        admission: String? = "retained",
        sourceSavedAt: String? = "2026-01-02T00:00:00Z",
        sourcePublishedAt: String? = nil,
        ageBasis: String = "sourceSavedAt",
        ageDays: Int = 12,
        freshness: String = "fresh",
        verdict: String? = "evergreen",
        supersededBy: String? = nil,
        hasTake: Bool = true,
        tagsStale: Bool = false,
        tags: [(String, String)] = [("systems", "Systems")],
        preview: (hash: String, mediaType: String, bytes: Int)? = nil,
        summary: String? = nil
    ) -> String {
        var fields: [String] = [
            #""schemaVersion":1"#,
            #""id":"\#(id)""#,
            #""revisionId":"\#(revisionId)""#,
            #""scope":"\#(scope)""#,
            #""createdAt":"2026-01-01T00:00:00Z""#,
            #""updatedAt":"2026-01-02T00:00:00Z""#,
            #""title":"\#(title)""#,
            #""captureDisposition":"\#(captureDisposition)""#,
        ]
        if let uri { fields.append(#""uri":"\#(uri)""#) }
        if let originalUri { fields.append(#""originalUri":"\#(originalUri)""#) }
        if let mediaType { fields.append(#""mediaType":"\#(mediaType)""#) }
        if let admission { fields.append(#""admission":"\#(admission)""#) }
        if let sourceSavedAt { fields.append(#""sourceSavedAt":"\#(sourceSavedAt)""#) }
        if let sourcePublishedAt { fields.append(#""sourcePublishedAt":"\#(sourcePublishedAt)""#) }
        fields.append(#""ageBasis":"\#(ageBasis)""#)
        fields.append(#""ageDays":\#(ageDays)"#)
        fields.append(#""freshness":"\#(freshness)""#)
        if let verdict { fields.append(#""verdict":"\#(verdict)""#) }
        if let supersededBy { fields.append(#""supersededBy":"\#(supersededBy)""#) }
        fields.append(#""hasTake":\#(hasTake)"#)
        fields.append(#""tagsStale":\#(tagsStale)"#)
        fields.append("\"tags\":[{" + tags.map { "\"id\":\"\($0.0)\",\"label\":\"\($0.1)\"}" }.joined(separator: ",") + "]")
        if let preview {
            fields.append(#""preview":{"hash":"\#(preview.hash)","mediaType":"\#(preview.mediaType)","bytes":\#(preview.bytes)}"#)
        }
        if let summary { fields.append(#""summary":"\#(summary)""#) }
        return "{\(fields.joined(separator: ","))}"
    }

    static func pageJSON(rows: [String], nextCursor: String? = nil, stateRevision: Int = 7) -> String {
        let cursor = nextCursor.map { #""nextCursor":"\#($0)","# } ?? ""
        return #"{"rows":[\#(rows.joined(separator: ","))],\#(cursor)"stateRevision":\#(stateRevision)}"#
    }

    static func row(_ json: String) throws -> KnowledgeSourceRow {
        try JSONDecoder.gateway.decode(KnowledgeSourceRow.self, from: Data(json.utf8))
    }

    /// A 64-character content address, as the Gateway publishes object hashes.
    static func hash(_ character: Character) -> String { String(repeating: String(character), count: 64) }
}

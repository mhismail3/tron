import XCTest
@testable import TronMobile

/// Tests for DraftAttachmentMetadata Codable round-trips
final class DraftMetadataTests: XCTestCase {

    // MARK: - DraftAttachmentMetadata Round-Trip

    @MainActor
    func testAttachmentMetadata_encodingDecodingRoundTrip() throws {
        let metadata = DraftAttachmentMetadata(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            type: .image,
            mimeType: "image/jpeg",
            fileName: "photo.jpg",
            originalSize: 1024,
            wasConverted: false,
            originalMimeType: nil
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DraftAttachmentMetadata.self, from: data)

        XCTAssertEqual(decoded.id, metadata.id)
        XCTAssertEqual(decoded.type, metadata.type)
        XCTAssertEqual(decoded.mimeType, metadata.mimeType)
        XCTAssertEqual(decoded.fileName, metadata.fileName)
        XCTAssertEqual(decoded.originalSize, metadata.originalSize)
        XCTAssertEqual(decoded.wasConverted, metadata.wasConverted)
        XCTAssertNil(decoded.originalMimeType)
    }

    @MainActor
    func testAttachmentMetadata_withConversion() throws {
        let metadata = DraftAttachmentMetadata(
            id: UUID(),
            type: .image,
            mimeType: "image/jpeg",
            fileName: "animation.gif",
            originalSize: 5000,
            wasConverted: true,
            originalMimeType: "image/gif"
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DraftAttachmentMetadata.self, from: data)

        XCTAssertTrue(decoded.wasConverted)
        XCTAssertEqual(decoded.originalMimeType, "image/gif")
    }

    @MainActor
    func testAttachmentMetadata_pdfType() throws {
        let metadata = DraftAttachmentMetadata(
            id: UUID(),
            type: .pdf,
            mimeType: "application/pdf",
            fileName: "document.pdf",
            originalSize: 50000,
            wasConverted: false,
            originalMimeType: nil
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DraftAttachmentMetadata.self, from: data)

        XCTAssertEqual(decoded.type, .pdf)
        XCTAssertEqual(decoded.mimeType, "application/pdf")
    }

    @MainActor
    func testAttachmentMetadata_documentType() throws {
        let metadata = DraftAttachmentMetadata(
            id: UUID(),
            type: .document,
            mimeType: "text/plain",
            fileName: nil,
            originalSize: 256,
            wasConverted: false,
            originalMimeType: nil
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(DraftAttachmentMetadata.self, from: data)

        XCTAssertEqual(decoded.type, .document)
        XCTAssertNil(decoded.fileName)
    }

    // MARK: - Array Encoding

    @MainActor
    func testAttachmentMetadataArray_encodingDecodingRoundTrip() throws {
        let array = [
            DraftAttachmentMetadata(id: UUID(), type: .image, mimeType: "image/jpeg", fileName: "a.jpg", originalSize: 100, wasConverted: false, originalMimeType: nil),
            DraftAttachmentMetadata(id: UUID(), type: .pdf, mimeType: "application/pdf", fileName: "b.pdf", originalSize: 200, wasConverted: false, originalMimeType: nil),
            DraftAttachmentMetadata(id: UUID(), type: .document, mimeType: "text/plain", fileName: nil, originalSize: 50, wasConverted: false, originalMimeType: nil),
        ]

        let data = try JSONEncoder().encode(array)
        let decoded = try JSONDecoder().decode([DraftAttachmentMetadata].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].type, .image)
        XCTAssertEqual(decoded[1].type, .pdf)
        XCTAssertEqual(decoded[2].type, .document)
    }

    @MainActor
    func testAttachmentMetadataArray_emptyArray() throws {
        let array: [DraftAttachmentMetadata] = []

        let data = try JSONEncoder().encode(array)
        let decoded = try JSONDecoder().decode([DraftAttachmentMetadata].self, from: data)

        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Skill Array Encoding in Draft Context

    @MainActor
    func testSkillArray_encodingDecodingRoundTrip() throws {
        let skills = [
            Skill(name: "test-skill", displayName: "Test Skill", description: "A test", source: .global, tags: ["tag1"]),
            Skill(name: "project-skill", displayName: "Project", description: "Project skill", source: .project, tags: nil, scopeDir: "packages/ios-app"),
        ]

        let data = try JSONEncoder().encode(skills)
        let decoded = try JSONDecoder().decode([Skill].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "test-skill")
        XCTAssertEqual(decoded[0].source, .global)
        XCTAssertEqual(decoded[0].tags, ["tag1"])
        XCTAssertEqual(decoded[1].name, "project-skill")
        XCTAssertEqual(decoded[1].source, .project)
        XCTAssertEqual(decoded[1].scopeDir, "packages/ios-app")
        XCTAssertNil(decoded[1].tags)
    }

    @MainActor
    func testSkillArray_emptyArray() throws {
        let skills: [Skill] = []

        let data = try JSONEncoder().encode(skills)
        let decoded = try JSONDecoder().decode([Skill].self, from: data)

        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Equatable

    @MainActor
    func testAttachmentMetadata_equatable() {
        let id = UUID()
        let a = DraftAttachmentMetadata(id: id, type: .image, mimeType: "image/jpeg", fileName: "a.jpg", originalSize: 100, wasConverted: false, originalMimeType: nil)
        let b = DraftAttachmentMetadata(id: id, type: .image, mimeType: "image/jpeg", fileName: "a.jpg", originalSize: 100, wasConverted: false, originalMimeType: nil)
        let c = DraftAttachmentMetadata(id: UUID(), type: .image, mimeType: "image/jpeg", fileName: "a.jpg", originalSize: 100, wasConverted: false, originalMimeType: nil)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

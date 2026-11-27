import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ArtifactShareViewTests: ShuffledTestCase {
    func testArtifactViewerSharesThePageOrSaysWhyNot() async throws {
        try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts", "-artifacts-base-url", "https://127.0.0.1:9"]) { app in
            try await app.activate("Artifacts")
            try await app.activate("artifact-row-usage-dashboard")
            try await app.until("the unreachable page's failure") {
                MountedFixture.elements(in: app.top).contains { $0.accessibilityLabel?.hasPrefix("The page could not be opened") == true }
            }
            XCTAssertNotNil(app.button("Open in Safari"))
            try await app.activate("Share")
            try await app.until("the share failure is shown, never silent") {
                MountedFixture.elements(in: app.top).contains { $0.accessibilityLabel?.hasPrefix("The page could not be shared") == true }
            }
        }
    }

    func testSharedFileIsThePageNamedAfterItsTitle() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appending(path: "index.html")
        try Data("<title>Q3</title>".utf8).write(to: page)
        let entry = ArtifactEntry(name: "2026-11-26_q3", title: "Q3/Q4 report: draft", updatedAt: "", url: page)
        let file = try await entry.sharedFile()
        XCTAssertEqual(file.lastPathComponent, "Q3-Q4 report- draft.html")
        XCTAssertEqual(try Data(contentsOf: file), Data("<title>Q3</title>".utf8))
    }

    func testFinishedShareRemovesItsTemporaryCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appending(path: "index.html")
        try Data("<title>Q4</title>".utf8).write(to: page)
        let file = try await ArtifactEntry(name: "2026-11-27_q4", title: "Q4", updatedAt: "", url: page).sharedFile()
        let copy = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: copy) }
        let controller = ArtifactEntry.activityController(sharing: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The copy stays while the share sheet holds it")
        controller.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "A finished share leaves no temporary copy behind")
    }
}

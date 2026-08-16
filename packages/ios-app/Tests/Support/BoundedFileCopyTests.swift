import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded file copy")
struct BoundedFileCopyTests {
    @Test("source growth is rejected before bytes exceed the reservation")
    func rejectsGrowthWithinReservation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bounded-copy-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source")
        let destination = directory.appending(path: "destination")
        try Data(repeating: 1, count: 65_537).write(to: source)

        await #expect(throws: BoundedFileCopyError.self) {
            try await BoundedFileCopy.copy(from: source, to: destination, expectedSize: 65_536)
        }
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 65_536)
    }
}

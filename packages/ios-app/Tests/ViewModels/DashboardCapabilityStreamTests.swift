import XCTest
@testable import TronMobile

@MainActor
final class DashboardCapabilityStreamTests: XCTestCase {
    func testSessionStreamBufferAddsCapabilityStartFromIdentity() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelToolName: "execute",
            contractId: "filesystem::read_file",
            implementationId: "first_party.filesystem.v1.read_file",
            functionId: "filesystem::read_file"
        )

        buffer.addCapabilityStart(
            identity: identity,
            invocationId: "call_read",
            arguments: ["path": AnyCodable("/tmp/example.txt")]
        )

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].modelToolName, "filesystem::read_file")
        XCTAssertEqual(buffer.lines[0].displayName, "Read File")
        XCTAssertEqual(buffer.lines[0].icon, "doc.text.magnifyingglass")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }

    func testSessionStreamBufferAddsCapabilityEndWithRiskAwarePresentation() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelToolName: "execute",
            contractId: "process::run",
            implementationId: "first_party.process.v1.run",
            functionId: "process::run"
        )

        buffer.addCapabilityEnd(identity: identity, success: false, durationMs: 250)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].displayName, "Run")
        XCTAssertEqual(buffer.lines[0].icon, "terminal")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronInfo)
        XCTAssertEqual(buffer.lines[0].duration, "250ms")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }
}

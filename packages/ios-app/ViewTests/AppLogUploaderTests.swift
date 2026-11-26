import XCTest
@testable import TronMobileCore
@testable import TronMobile

@MainActor
final class AppLogUploaderTests: XCTestCase {
    private final class PassCounter {
        var value = 0
    }

    func testUploaderSleepsBetweenTimedPassesAndWakesOnNudge() async throws {
        let log = AppLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "uploader-\(UUID().uuidString)/app.jsonl"))

        let timedPasses = PassCounter()
        let timed = AppLogUploader(log: log, interval: .milliseconds(100)) { timedPasses.value += 1; return nil }
        defer { timed.stop() }
        timed.start()
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThanOrEqual(timedPasses.value, 2, "the interval timer must start the next pass")
        XCTAssertLessThanOrEqual(timedPasses.value, 15, "after the timer wins, each pass must still wait one interval (#2692)")

        let nudgedPasses = PassCounter()
        let nudged = AppLogUploader(log: log) { nudgedPasses.value += 1; return nil }
        defer { nudged.stop() }
        nudged.start()
        try await waitUntil("the first pass on start") { nudgedPasses.value == 1 }
        nudged.nudge()
        try await waitUntil("a nudged pass") { nudgedPasses.value == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(nudgedPasses.value, 2, "one nudge starts exactly one pass")
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

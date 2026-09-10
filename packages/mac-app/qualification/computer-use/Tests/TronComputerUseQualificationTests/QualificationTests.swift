import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import PeekabooAutomationKit

private actor Latch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class QualificationTests: XCTestCase {
    private func context() -> CaptureCoordinateContext {
        CaptureCoordinateContext(metadata: CaptureMetadata(
            size: CGSize(width: 100, height: 80), mode: .area,
            displayInfo: DisplayInfo(index: 0, name: "Synthetic",
                bounds: CGRect(x: -600, y: 40, width: 200, height: 160), scaleFactor: 2)))
    }

    func testNativeMapperUsesDeliveredDimensionsAndNegativeOrigin() throws {
        let point = try CaptureCoordinateMapper.globalPoint(
            for: CGPoint(x: 25, y: 20), in: .imagePixels, context: context())
        XCTAssertEqual(point, CGPoint(x: -550, y: 80))
        let normalized = try CaptureCoordinateMapper.globalPoint(
            for: CGPoint(x: 0.25, y: 0.25), in: .normalized, context: context())
        XCTAssertEqual(normalized, point)
    }

    func testNativeMapperRejectsNonfiniteAndOutsideImageCoordinates() {
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: -1, y: 0),
                      CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 80)] {
            XCTAssertThrowsError(try CaptureCoordinateMapper.globalPoint(
                for: point, in: .imagePixels, context: context()))
        }
    }

    func testActualNativeFileClaimSurvivesCancellationUntilBodyReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let entered = Latch()
        let release = Latch()
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let work = Task {
            do {
                return try await coordinator.run(scope: .global, access: .write) {
                    await entered.open()
                    await release.wait() // deliberately ignores task cancellation
                    return "native body returned"
                }
            } catch {
                await entered.open() // admission failure cannot strand readiness
                throw error
            }
        }
        await entered.wait()
        work.cancel()
        do {
            // A different process probes the actual flock, not a test actor's
            // owner flag. The cancelled Swift waiter cannot make it available.
            XCTAssertEqual(try contender(root), 75)
            await release.open()
            let result = try await work.value
            XCTAssertEqual(result, "native body returned")
            XCTAssertEqual(try contender(root), 0)
            try FileManager.default.removeItem(at: root)
        } catch {
            await release.open()
            _ = try? await work.value
            throw error
        }
    }

    private func contender(_ root: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(75)
        finally:
            os.close(fd)
        """, root.appendingPathComponent("global.lock").path]
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + 5) == .success else {
            process.terminate() // only this exact test-created child
            _ = ended.wait(timeout: .now() + 2)
            throw NSError(domain: "qualification-contender-timeout", code: 1)
        }
        return process.terminationStatus
    }
}

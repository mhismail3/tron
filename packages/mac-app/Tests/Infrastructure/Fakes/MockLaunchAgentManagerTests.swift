import Foundation
import Testing
@testable import TronMac

/// Sanity-check that the test fixture itself behaves predictably so
/// downstream tests (eventual InstallStep flow + MenuBar Restart) can
/// rely on it.
@Suite("MockLaunchAgentManager")
struct MockLaunchAgentManagerTests {
    @Test("records the load call with plist path and label")
    func recordsLoad() async throws {
        let mock = MockLaunchAgentManager()
        let url = URL(fileURLWithPath: "/tmp/p.plist")
        let outcome = await mock.load(plistPath: url, label: "com.tron.server")
        #expect(outcome == .ok)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].kind == .load)
        #expect(mock.calls[0].label == "com.tron.server")
        #expect(mock.calls[0].plistPath == url)
    }

    @Test("returns configured outcomes")
    func configurableOutcomes() async throws {
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .launchdRefused(message: "nope")
        let outcome = await mock.load(plistPath: URL(fileURLWithPath: "/x"), label: "y")
        #expect(outcome == .launchdRefused(message: "nope"))
    }

    @Test("isLoaded honors the loaded property")
    func isLoadedHonored() async throws {
        let mock = MockLaunchAgentManager()
        mock.loaded = true
        let result = await mock.isLoaded(label: "x")
        #expect(result == true)
    }

    @Test("calls accumulate across operations")
    func callsAccumulate() async throws {
        let mock = MockLaunchAgentManager()
        _ = await mock.load(plistPath: URL(fileURLWithPath: "/a"), label: "x")
        _ = await mock.unload(label: "x")
        _ = await mock.restart(label: "x")
        _ = await mock.isLoaded(label: "x")
        #expect(mock.calls.map(\.kind) == [.load, .unload, .restart, .isLoaded])
    }
}

import Foundation
import os
@testable import TronMac

/// In-memory `LaunchAgentManaging` stand-in for tests. Each call is
/// recorded so the test can assert the exact sequence of ops the install
/// pipeline dispatched. All four entry points return a configurable
/// `LaunchAgentOutcome`.
///
/// State is guarded by `OSAllocatedUnfairLock`, the async-safe lock
/// primitive Apple recommends for Swift 6 — `NSLock` is explicitly
/// unavailable in async contexts because it blocks the calling thread.
final class MockLaunchAgentManager: LaunchAgentManaging, @unchecked Sendable {
    struct Call: Equatable {
        enum Kind: Equatable { case load, unload, restart, isLoaded, runtimeInfo }
        let kind: Kind
        let label: String
        let plistPath: URL?
    }

    private struct State {
        var calls: [Call] = []
        var loadOutcome: LaunchAgentOutcome = .ok
        var unloadOutcome: LaunchAgentOutcome = .ok
        var restartOutcome: LaunchAgentOutcome = .ok
        var loaded: Bool = false
        var runtimeInfo: LaunchAgentRuntimeInfo?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var loadOutcome: LaunchAgentOutcome {
        get { state.withLock { $0.loadOutcome } }
        set { state.withLock { $0.loadOutcome = newValue } }
    }
    var unloadOutcome: LaunchAgentOutcome {
        get { state.withLock { $0.unloadOutcome } }
        set { state.withLock { $0.unloadOutcome = newValue } }
    }
    var restartOutcome: LaunchAgentOutcome {
        get { state.withLock { $0.restartOutcome } }
        set { state.withLock { $0.restartOutcome = newValue } }
    }
    var loaded: Bool {
        get { state.withLock { $0.loaded } }
        set { state.withLock { $0.loaded = newValue } }
    }
    var runtimeInfo: LaunchAgentRuntimeInfo? {
        get { state.withLock { $0.runtimeInfo } }
        set { state.withLock { $0.runtimeInfo = newValue } }
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome {
        state.withLock {
            $0.calls.append(Call(kind: .load, label: label, plistPath: plistPath))
            return $0.loadOutcome
        }
    }

    func unload(label: String) async -> LaunchAgentOutcome {
        state.withLock {
            $0.calls.append(Call(kind: .unload, label: label, plistPath: nil))
            return $0.unloadOutcome
        }
    }

    func restart(label: String) async -> LaunchAgentOutcome {
        state.withLock {
            $0.calls.append(Call(kind: .restart, label: label, plistPath: nil))
            return $0.restartOutcome
        }
    }

    func isLoaded(label: String) async -> Bool {
        state.withLock {
            $0.calls.append(Call(kind: .isLoaded, label: label, plistPath: nil))
            return $0.loaded
        }
    }

    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo? {
        state.withLock {
            $0.calls.append(Call(kind: .runtimeInfo, label: label, plistPath: nil))
            return $0.runtimeInfo
        }
    }
}

/// Creates a throwaway directory under `NSTemporaryDirectory()` for a
/// test. The returned URL is cleaned up by the caller's `defer`.
enum TestTempDir {
    static func make(file: StaticString = #file, line: UInt = #line) -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("tron-mac-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

func macAppRoot(filePath: String = #filePath) -> URL {
    var candidate = URL(fileURLWithPath: filePath)
    while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appending(path: "project.yml").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate packages/mac-app root from \\(filePath)")
}

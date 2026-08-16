import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Workspace browser request ownership")
struct WorkspaceBrowserOwnerTests {
    @Test("superseded failure cannot clear or overwrite the newest navigation")
    func newestRequestOwnsPresentationState() async {
        let probe = WorkspaceLoadProbe()
        let owner = WorkspaceBrowserOwner()
        let first = Task {
            await owner.load(
                navigation: false,
                operation: { try await probe.run("first", failureMessage: "old") },
                onTransientError: {}
            )
        }
        await probe.waitUntilStarted("first")
        #expect(owner.loading)

        let second = Task {
            await owner.load(
                navigation: true,
                operation: { try await probe.run("second", failureMessage: nil) },
                onTransientError: {}
            )
        }
        await probe.waitUntilStarted("second")
        #expect(!owner.loading)
        #expect(owner.navigating)
        await probe.release("second")
        await second.value
        #expect(!owner.navigating)
        #expect(owner.errorMessage == nil)

        await probe.release("first")
        await first.value
        #expect(!owner.loading)
        #expect(!owner.navigating)
        #expect(owner.errorMessage == nil)
    }

    @Test("dismissal cancellation retires visible phase and rejects late failure")
    func cancellationRetiresState() async {
        let probe = WorkspaceLoadProbe()
        let owner = WorkspaceBrowserOwner()
        let loading = Task {
            await owner.load(
                navigation: false,
                operation: { try await probe.run("load", failureMessage: "late") },
                onTransientError: {}
            )
        }
        await probe.waitUntilStarted("load")
        #expect(owner.loading)

        owner.cancel()
        #expect(!owner.loading)
        #expect(!owner.navigating)
        await probe.release("load")
        await loading.value
        #expect(owner.errorMessage == nil)
    }

    @Test("navigation rejects late create-folder failure and owns submission phase")
    func navigationSupersedesFolderPresentation() async {
        let probe = WorkspaceLoadProbe()
        let owner = WorkspaceBrowserOwner()
        let creation = Task {
            await owner.createFolder(
                operation: { try await probe.run("create", failureMessage: "late create") },
                onSuccess: {},
                onTransientError: {}
            )
        }
        await probe.waitUntilStarted("create")
        #expect(owner.submittingFolder)

        let navigation = Task {
            await owner.load(
                navigation: true,
                operation: { try await probe.run("navigate", failureMessage: nil) },
                onTransientError: {}
            )
        }
        await probe.waitUntilStarted("navigate")
        #expect(!owner.submittingFolder)
        await probe.release("navigate")
        await navigation.value
        await probe.release("create")
        await creation.value
        #expect(owner.errorMessage == nil)
        #expect(!owner.submittingFolder)
    }

    @Test("only a current transient failure requests recovery")
    func transientRecoveryAdmission() async {
        let owner = WorkspaceBrowserOwner()
        var recoveries = 0
        await owner.load(
            navigation: false,
            operation: { throw WorkspaceProbeError.failed("Gateway is offline") },
            onTransientError: { recoveries += 1 }
        )

        #expect(recoveries == 1)
        #expect(owner.errorMessage == "Gateway is offline")
        #expect(!owner.loading)

        await owner.createFolder(
            operation: { throw WorkspaceProbeError.failed("socket is not connected") },
            onSuccess: {},
            onTransientError: { recoveries += 1 }
        )
        #expect(recoveries == 2)
        #expect(owner.errorMessage == "socket is not connected")
        #expect(!owner.submittingFolder)
    }
}

private enum WorkspaceProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

private actor WorkspaceLoadProbe {
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []

    func run(_ id: String, failureMessage: String?) async throws {
        started.insert(id)
        startWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        if !released.contains(id) {
            await withCheckedContinuation { releases[id] = $0 }
        }
        if let failureMessage { throw WorkspaceProbeError.failed(failureMessage) }
    }

    func waitUntilStarted(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { startWaiters[id, default: []].append($0) }
    }

    func release(_ id: String) {
        released.insert(id)
        releases.removeValue(forKey: id)?.resume()
    }
}

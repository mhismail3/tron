import Testing
@testable import TronMobile

@Suite("Session Context Refresh Coordinator")
@MainActor
struct SessionContextRefreshCoordinatorTests {
    @Test("Invalidation during a read guarantees one follow-up")
    func invalidationDuringReadGuaranteesFollowUp() async {
        let coordinator = SessionContextRefreshCoordinator()
        var calls = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        var secondCompleted = false
        let operation: SessionContextRefreshCoordinator.Operation = { _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
            } else {
                secondCompleted = true
            }
        }

        coordinator.request(.workers, operation: operation)
        while calls == 0 {
            await Task.yield()
        }
        coordinator.request(.workers, operation: operation)
        coordinator.request(.workers, operation: operation)
        releaseFirst?.resume()
        while !secondCompleted {
            await Task.yield()
        }

        #expect(calls == 2)
    }

    @Test("Independent lanes never cancel one another")
    func independentLanesNeverCancelOneAnother() async {
        let coordinator = SessionContextRefreshCoordinator()
        var releaseWorkers: CheckedContinuation<Void, Never>?
        var workerStarted = false
        var contextCompleted = false

        coordinator.request(.workers) { _ in
            workerStarted = true
            await withCheckedContinuation { continuation in
                releaseWorkers = continuation
            }
        }
        while !workerStarted {
            await Task.yield()
        }
        coordinator.request(.providerContext) { _ in
            contextCompleted = true
        }
        while !contextCompleted {
            await Task.yield()
        }

        #expect(contextCompleted)
        releaseWorkers?.resume()
    }

    @Test("Reset prevents an old generation from applying")
    func resetPreventsStaleGenerationApplication() async {
        let coordinator = SessionContextRefreshCoordinator()
        var releaseOld: CheckedContinuation<Void, Never>?
        var oldStarted = false
        var staleApplied = false
        var currentApplied = false

        coordinator.request(.agentUpdates) { generation in
            oldStarted = true
            await withCheckedContinuation { continuation in
                releaseOld = continuation
            }
            if coordinator.isCurrent(generation) {
                staleApplied = true
            }
        }
        while !oldStarted {
            await Task.yield()
        }

        coordinator.reset()
        coordinator.request(.agentUpdates) { generation in
            if coordinator.isCurrent(generation) {
                currentApplied = true
            }
        }
        releaseOld?.resume()
        while !currentApplied {
            await Task.yield()
        }

        #expect(!staleApplied)
        #expect(currentApplied)
    }
}

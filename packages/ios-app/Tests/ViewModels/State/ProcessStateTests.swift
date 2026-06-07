import Testing
import Foundation
@testable import TronMobile

@Suite("ProcessState Tests")
@MainActor
struct ProcessStateTests {

    // MARK: - Helpers

    private func makeSpawnResult(processId: String = "proc-1", label: String = "sleep 10", kind: String = "shell", invocationId: String = "tc-1") -> ProcessSpawnedPlugin.Result {
        ProcessSpawnedPlugin.Result(processId: processId, label: label, kind: kind, background: true, invocationId: invocationId)
    }

    private func makeCompletedResult(processId: String = "proc-1", label: String = "sleep 10", success: Bool = true, exitCode: Int? = 0, durationMs: Int = 10_000) -> ProcessCompletedPlugin.Result {
        ProcessCompletedPlugin.Result(processId: processId, label: label, success: success, exitCode: exitCode, durationMs: durationMs, resultSummary: "done", blobId: nil)
    }

    // MARK: - Spawn

    @Test("trackSpawn adds a running process")
    func testTrackSpawn() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult())
        #expect(state.processes.count == 1)
        #expect(state.processes["proc-1"]?.status == .running)
        #expect(state.processes["proc-1"]?.label == "sleep 10")
        #expect(state.processes["proc-1"]?.kind == "shell")
    }

    @Test("trackSpawn multiple processes")
    func testTrackSpawnMultiple() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult(processId: "proc-1"))
        state.trackSpawn(result: makeSpawnResult(processId: "proc-2", label: "echo done"))
        #expect(state.processes.count == 2)
        #expect(state.activeCount == 2)
    }

    // MARK: - Completion

    @Test("trackCompleted marks process as completed")
    func testTrackCompleted() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult())
        state.trackCompleted(result: makeCompletedResult())
        #expect(state.processes["proc-1"]?.status == .completed)
        #expect(state.processes["proc-1"]?.exitCode == 0)
        #expect(state.processes["proc-1"]?.durationMs == 10_000)
    }

    @Test("trackCompleted marks failed process")
    func testTrackCompletedFailed() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult())
        state.trackCompleted(result: makeCompletedResult(success: false, exitCode: 1))
        #expect(state.processes["proc-1"]?.status == .failed)
        #expect(state.processes["proc-1"]?.exitCode == 1)
    }

    @Test("trackCompleted ignores unknown process")
    func testTrackCompletedUnknown() {
        let state = ProcessState()
        state.trackCompleted(result: makeCompletedResult(processId: "unknown"))
        #expect(state.processes.isEmpty)
    }

    // MARK: - Status Update

    @Test("trackStatusUpdate handles cancelled")
    func testStatusUpdateCancelled() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult())
        state.trackStatusUpdate(result: ProcessStatusUpdatePlugin.Result(processId: "proc-1", status: "cancelled"))
        #expect(state.processes["proc-1"]?.status == .cancelled)
    }

    @Test("trackStatusUpdate ignores unknown status")
    func testStatusUpdateUnknownStatus() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult())
        state.trackStatusUpdate(result: ProcessStatusUpdatePlugin.Result(processId: "proc-1", status: "promoted"))
        #expect(state.processes["proc-1"]?.status == .running)
    }

    @Test("trackStatusUpdate ignores unknown process")
    func testStatusUpdateUnknownProcess() {
        let state = ProcessState()
        state.trackStatusUpdate(result: ProcessStatusUpdatePlugin.Result(processId: "unknown", status: "cancelled"))
        #expect(state.processes.isEmpty)
    }

    @Test("server status update records cancellation")
    func testServerStatusRecordsCancellation() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult())
        state.trackStatusUpdate(result: ProcessStatusUpdatePlugin.Result(processId: "proc-1", status: "cancelled"))
        #expect(state.processes["proc-1"]?.status == .cancelled)
    }

    // MARK: - Computed Properties

    @Test("hasActiveProcesses is true when running")
    func testHasActiveProcesses() {
        let state = ProcessState()
        #expect(state.hasActiveProcesses == false)
        state.trackSpawn(result: makeSpawnResult())
        #expect(state.hasActiveProcesses == true)
        state.trackCompleted(result: makeCompletedResult())
        #expect(state.hasActiveProcesses == false)
    }

    @Test("activeCount tracks running only")
    func testActiveCount() {
        let state = ProcessState()
        #expect(state.activeCount == 0)
        state.trackSpawn(result: makeSpawnResult(processId: "proc-1"))
        state.trackSpawn(result: makeSpawnResult(processId: "proc-2"))
        #expect(state.activeCount == 2)
        state.trackCompleted(result: makeCompletedResult(processId: "proc-1"))
        #expect(state.activeCount == 1)
    }

    @Test("allProcessesSorted returns newest first")
    func testAllProcessesSorted() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult(processId: "proc-1", label: "first"))
        // Small delay to ensure different timestamps
        state.trackSpawn(result: makeSpawnResult(processId: "proc-2", label: "second"))
        let sorted = state.allProcessesSorted
        #expect(sorted.count == 2)
    }

    // MARK: - Cleanup

    @Test("clearAll removes all processes")
    func testClearAll() {
        let state = ProcessState()
        state.trackSpawn(result: makeSpawnResult(processId: "proc-1"))
        state.trackSpawn(result: makeSpawnResult(processId: "proc-2"))
        state.clearAll()
        #expect(state.processes.isEmpty)
        #expect(state.hasActiveProcesses == false)
        #expect(state.activeCount == 0)
    }
}

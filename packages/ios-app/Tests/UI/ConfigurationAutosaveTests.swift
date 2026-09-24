import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class ConfigurationAutosaveTests: XCTestCase {
    private let global = ConfigurationAutosaveCoordinator.Key.settings(.global, sessionID: nil)

    func testCoalescesSparseFieldsAndKeepsReversionsAndNulls() async {
        let queue = ConfigurationAutosaveCoordinator()
        defer { queue.clearProfile() }
        let finished = expectation(description: "coalesced write")
        var writes: [JSONValue] = []
        queue.submit(key: global, patch: .object(["retry": .object(["enabled": .bool(false)])]), write: { _ in XCTFail("Superseded operation") })
        queue.submit(key: global, patch: .object(["retry": .object(["maxRetries": .number(7)])]), write: { _ in XCTFail("Superseded operation") })
        queue.submit(key: global, patch: .object([
            "retry": .object(["enabled": .bool(true)]), "modelContextWindows": .object(["test/model": .null])
        ]), write: { value in writes.append(value!) }, completed: { finished.fulfill() })
        queue.flush()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(writes, [.object([
            "retry": .object(["enabled": .bool(true), "maxRetries": .number(7)]),
            "modelContextWindows": .object(["test/model": .null])
        ])])
    }

    func testInFlightChangeDoesNotLoseItsReversion() async {
        let queue = ConfigurationAutosaveCoordinator()
        let gate = TestReadGate()
        let entered = expectation(description: "first write entered")
        let firstDone = expectation(description: "first write settled")
        let latestDone = expectation(description: "latest write settled")
        var writes: [JSONValue] = []
        queue.submit(key: global, patch: .object(["enabled": .bool(false)]), write: { value in
            writes.append(value!)
            entered.fulfill()
            await gate.wait()
        }, completed: { firstDone.fulfill() })
        queue.flush()
        await fulfillment(of: [entered], timeout: 2)
        queue.submit(key: global, patch: .object(["enabled": .bool(true)]), write: { value in
            writes.append(value!)
        }, completed: { latestDone.fulfill() })
        queue.flush()
        XCTAssertEqual(writes.count, 1, "No overlapping configuration writes")
        await gate.release()
        await fulfillment(of: [firstDone], timeout: 2)
        queue.flush()
        await fulfillment(of: [latestDone], timeout: 2)
        XCTAssertEqual(writes, [.object(["enabled": .bool(false)]), .object(["enabled": .bool(true)])])
        queue.clearProfile()
    }

    func testScopeOrderAndLatestDocumentReplacement() async {
        let queue = ConfigurationAutosaveCoordinator()
        defer { queue.clearProfile() }
        let done = expectation(description: "all targets settled")
        done.expectedFulfillmentCount = 3
        let project = ConfigurationAutosaveCoordinator.Key.settings(.project(cwd: "/workspace/example"), sessionID: "session")
        let custom = ConfigurationAutosaveCoordinator.Key.customModels(.global)
        var order: [String] = []
        queue.submit(key: global, patch: .object(["value": .string("global")]), write: { _ in order.append("global") }, completed: { done.fulfill() })
        queue.submit(key: project, patch: .object(["value": .string("project")]), write: { _ in order.append("project") }, completed: { done.fulfill() })
        queue.submit(key: custom, write: { _ in XCTFail("Old complete document must be replaced") })
        queue.submit(key: custom, write: { _ in order.append("latest document") }, completed: { done.fulfill() })
        queue.flush()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(order, ["global", "project", "latest document"])
    }

    func testUncertainOutcomeRequiresExplicitRetryEvenAfterAnotherEdit() async {
        let queue = ConfigurationAutosaveCoordinator()
        defer { queue.clearProfile() }
        let failed = expectation(description: "failure retained")
        let completed = expectation(description: "explicit retry")
        queue.didFail = { _ in failed.fulfill() }
        var attempts = 0
        queue.submit(key: global, patch: .object(["retry": .object(["enabled": .bool(false)])]), write: { _ in
            attempts += 1
            throw GatewayFailure(code: "outcome_unknown", message: "Verify before retry", retryable: false, details: nil)
        })
        queue.flush()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(queue.canRetry(global))
        var received: JSONValue?
        queue.submit(key: global, patch: .object(["retry": .object(["maxRetries": .number(4)])]), write: { value in
            attempts += 1
            received = value
        }, completed: { completed.fulfill() })
        queue.flush()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(queue.hasPending(global))
        queue.retry(global)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(received, .object(["retry": .object(["enabled": .bool(false), "maxRetries": .number(4)])]))
        XCTAssertNil(queue.error(for: global))
    }

    func testProfileRetirementBeforeDispatchCannotWriteIntoSuccessor() async {
        let queue = ConfigurationAutosaveCoordinator()
        defer { queue.clearProfile() }
        var staleWrites = 0
        queue.submit(key: global, patch: .object(["value": .number(1)]), write: { _ in staleWrites += 1 })
        queue.flush() // Starts a task, but its actor turn has not run yet.
        queue.clearProfile()
        let done = expectation(description: "new profile write")
        queue.submit(key: global, patch: .object(["value": .number(2)]), write: { _ in }, completed: { done.fulfill() })
        queue.flush()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(staleWrites, 0)
    }

    func testProjectionInstallationAndOldScopeBindingNeverAutosave() async {
        let model = AppModel()
        var value = AgentDefaultsDraft()
        var store = ScopedSettingsDraftStore<AgentDefaultsDraft>()
        store.install(value, for: .global)
        let binding = SettingsAutosave.binding(
            draft: Binding(get: { value }, set: { value = $0 }),
            store: Binding(get: { store }, set: { store = $0 }),
            model: model, target: .global, admits: { true }, patch: { $0.patch(comparedTo: $1) }
        )
        _ = binding.wrappedValue
        value.retryCount = 8
        store.install(value, for: .global)
        XCTAssertFalse(model.configurationAutosave.hasPending(global))
        let project = SettingsTarget.project(cwd: "/workspace/example")
        _ = store.draftForScopeSwitch(current: value, from: .global, to: project, default: AgentDefaultsDraft())
        _ = store.draftForScopeSwitch(current: AgentDefaultsDraft(), from: project, to: .global, default: AgentDefaultsDraft())
        var stale = value
        stale.retryCount = 99
        binding.wrappedValue = stale
        XCTAssertEqual(value.retryCount, 8)
        XCTAssertFalse(model.configurationAutosave.hasPending(global))
        await model.teardown()
    }

    func testRetiredInputBindingCannotSubmitBeforeTheFacadeProfileRevisionUpdates() async {
        let model = AppModel()
        var value = AgentDefaultsDraft()
        var store = ScopedSettingsDraftStore<AgentDefaultsDraft>()
        store.install(value, for: .global)
        let binding = SettingsAutosave.binding(
            draft: Binding(get: { value }, set: { value = $0 }),
            store: Binding(get: { store }, set: { store = $0 }),
            model: model, target: .global, admits: { true }, patch: { $0.patch(comparedTo: $1) }
        )
        let revision = model.profileRevision
        model.configurationAutosave.clearProfile()
        XCTAssertEqual(model.profileRevision, revision)
        binding.update { $0.retryCount = 99 }
        XCTAssertEqual(value.retryCount, 3)
        XCTAssertFalse(model.configurationAutosave.hasPending(global))
        await model.teardown()
    }

    func testExplicitChoiceAfterQueuedInheritanceResetIsNotLost() {
        var inherited = CompactionSettingsDraft()
        inherited.useGlobalPolicy(from: CompactionSettingsDraft(thinkingLevel: "high"))
        var explicit = inherited
        explicit.setThinkingLevel("high")
        XCTAssertEqual(explicit.patch(comparedTo: inherited).objectValue?["compaction"]?.objectValue?["thinkingLevel"], .string("high"))
    }

    func testProviderEditorBindingSurvivesReorderAndRetiresOnRemoval() {
        let first = CustomModelProviderDraft()
        let second = CustomModelProviderDraft()
        var values = [first, second]
        let binding = first.editingBinding(in: Binding(get: { values }, set: { values = $0 }))
        values.reverse()
        binding.identifier.wrappedValue = "renamed"
        XCTAssertEqual(values.first(where: { $0.id == first.id })?.identifier, "renamed")
        XCTAssertEqual(values.first(where: { $0.id == second.id })?.identifier, "")
        values.removeAll { $0.id == first.id }
        binding.identifier.wrappedValue = "late callback"
        XCTAssertEqual(values.map(\.id), [second.id])
        XCTAssertEqual(values[0].identifier, "")
    }

    func testIncompleteCustomModelInputNeverProducesAReplacementDocument() throws {
        XCTAssertThrowsError(try CustomModelDraftTransformation.autosaveValue(advancedDocument: "{}", root: [:], providers: []))
        XCTAssertThrowsError(try CustomModelDraftTransformation.autosaveValue(advancedDocument: "{", root: [:], providers: []))
        XCTAssertThrowsError(try CustomModelDraftTransformation.autosaveValue(advancedDocument: nil, root: [:], providers: [CustomModelProviderDraft()]))
        XCTAssertEqual(try CustomModelDraftTransformation.autosaveValue(advancedDocument: "{\"providers\":{}}", root: [:], providers: []), .object(["providers": .object([:])]))
    }
}

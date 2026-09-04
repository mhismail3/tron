import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Package configuration coordinator")
struct PackageConfigurationCoordinatorTests {
    @Test("package refresh identity includes profile revision and row operation identity")
    func packageOwnershipIdentity() {
        let target = PackageConfigurationTarget.workspace(cwd: "/workspace/project")
        #expect(PackageLoadID(target: target, profileRevision: 1, invalidationGeneration: 2, refreshGeneration: 3) != PackageLoadID(target: target, profileRevision: 2, invalidationGeneration: 2, refreshGeneration: 3))
        #expect(PackageLoadID(target: target, profileRevision: 1, invalidationGeneration: 2, refreshGeneration: 3) != PackageLoadID(target: target, profileRevision: 1, invalidationGeneration: 3, refreshGeneration: 3))
        #expect(PackageInstallDraftPolicy.afterSuccess(current: "new draft", captured: "installed") == "new draft")
        #expect(PackageInstallDraftPolicy.afterSuccess(current: "installed", captured: "installed").isEmpty)
        let package = PackageSummary(source: "tool", scope: .project, filtered: false, installedPath: nil)
        let sameRowUpdate = PackageMutationOperation.update(package.id)
        let sameRowRemove = PackageMutationOperation.remove(package.id)
        #expect(package.id == "project:tool")
        #expect(sameRowUpdate != sameRowRemove)
    }

    @Test("resolved resource overview extracts bounded user-facing categories")
    func resourceSummary() throws {
        let resources = JSONValue.object([
            "extensions": .array([
                .object([
                    "path": .string("/packages/sample/extensions/browser.ts"),
                    "enabled": .bool(true),
                    "metadata": .object([
                        "source": .string("npm:sample"),
                        "scope": .string("user"),
                        "origin": .string("package"),
                    ]),
                ]),
            ]),
            "skills": .array([
                .object([
                    "path": .string("/packages/sample/skills/review/SKILL.md"),
                    "enabled": .bool(false),
                    "metadata": .object([
                        "source": .string("npm:sample"),
                        "scope": .string("project"),
                        "origin": .string("package"),
                    ]),
                ]),
            ]),
            "prompts": .array([]),
            "futureCategory": .array([.string("preserved only in technical JSON")]),
        ])
        let presentation = PackageResolvedResourcesPresentation(resources: resources)
        #expect(presentation.totalCount == 2)
        #expect(presentation.enabledCount == 1)
        #expect(presentation.disabledCount == 1)
        #expect(presentation.populatedCategoryCount == 2)
        #expect(presentation.additionalCategoryCount == 1)
        #expect(presentation.overview == "2 resources across 2 resource types. 1 is ready to use and 1 is turned off. Additional technical resource data is available below.")
        #expect(PackageResourceSummaryPolicy.summary(for: resources) == "2 known resolved resources")
        let skill = try #require(presentation.categories.first(where: { $0.kind == .skills })?.items.first)
        #expect(skill.displayName == "review")
        #expect(skill.sourceDescription == "From npm:sample · Current project")
        #expect(PackageResourceSummaryPolicy.summary(for: .object(["skills": .array([])])) == "No resources resolved")
        #expect(PackageResourceSummaryPolicy.summary(for: .string("opaque")) == "No resources resolved")
    }

    @Test("target-keyed inventories admit independently and newest same-target load wins")
    func inventoryAdmission() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let workspace = PackageConfigurationTarget.workspace(cwd: "/workspace/project")
            let global = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let project = Task { await harness.owner.load(target: workspace) }
            try await harness.socket.waitUntilSent(count: 3)
            let globalRequest = try request(await harness.socket.sentFrames()[1])
            let projectRequest = try request(await harness.socket.sentFrames()[2])
            #expect(globalRequest.method == "packages.list")
            #expect(globalRequest.params?["cwd"] == nil)
            #expect(projectRequest.params?["cwd"] == .string("/workspace/project"))
            await harness.socket.enqueue(response(id: projectRequest.id, result: inventory("project")))
            await harness.socket.enqueue(response(id: globalRequest.id, result: inventory("global")))
            #expect(await global.value)
            #expect(await project.value)
            #expect(harness.owner.inventory(for: .global)?.packages.first?.source == "global")
            #expect(harness.owner.inventory(for: workspace)?.packages.first?.source == "project")

            let older = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 4)
            let newer = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 5)
            let olderRequest = try request(await harness.socket.sentFrames()[3])
            let newerRequest = try request(await harness.socket.sentFrames()[4])
            await harness.socket.enqueue(response(id: newerRequest.id, result: inventory("newer")))
            #expect(await newer.value)
            await harness.socket.enqueue(response(id: olderRequest.id, result: inventory("older")))
            #expect(!(await older.value))
            #expect(harness.owner.inventory(for: .global)?.packages.first?.source == "newer")
            #expect(PackageConfigurationCoordinator.listTimeout == .seconds(120))
            await harness.client.close()
        }
    }

    @Test("newest update check wins and invalidation remains event-only")
    func updateAdmissionAndInvalidation() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.notePackagesChanged()
            let invalidation = harness.owner.invalidationGeneration
            let older = Task { await harness.owner.checkUpdates(target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let newer = Task { await harness.owner.checkUpdates(target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let olderRequest = try request(await harness.socket.sentFrames()[1])
            let newerRequest = try request(await harness.socket.sentFrames()[2])
            #expect(newerRequest.method == "packages.checkUpdates")
            await harness.socket.enqueue(response(id: newerRequest.id, result: updates(["newer"])))
            #expect(await newer.value)
            await harness.socket.enqueue(response(id: olderRequest.id, result: updates(["older"])))
            #expect(!(await older.value))
            #expect(harness.owner.updates(for: .global).map(\.source) == ["newer"])
            #expect(harness.owner.invalidationGeneration == invalidation)
            #expect(PackageConfigurationCoordinator.checkUpdatesTimeout == .seconds(180))
            await harness.client.close()
        }
    }

    @Test("only admitted errors surface and profile clear drops projections")
    func errorAndProfileAdmission() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let delegate = ErrorDelegate()
            harness.owner.delegate = delegate
            harness.owner.installHostedInventory(try inventory("retired").decode(PackageInventory.self), for: .global)
            let older = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let newer = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let olderRequest = try request(await harness.socket.sentFrames()[1])
            let newerRequest = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(failure(id: olderRequest.id, message: "stale"))
            #expect(!(await older.value))
            #expect(delegate.messages.isEmpty)
            await harness.socket.enqueue(failure(id: newerRequest.id, message: "admitted"))
            #expect(!(await newer.value))
            #expect(delegate.messages == ["admitted"])
            #expect(harness.owner.error(for: .global) == "admitted")

            let pending = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 4)
            let pendingRequest = try request(await harness.socket.sentFrames()[3])
            harness.owner.clearProfile()
            harness.owner.clearProfile() // A → B → A uses a distinct owner generation.
            #expect(harness.owner.inventory(for: .global) == nil)
            await harness.socket.enqueue(response(id: pendingRequest.id, result: inventory("late")))
            #expect(!(await pending.value))
            #expect(harness.owner.inventory(for: .global) == nil)
            await harness.client.close()
        }
    }

    @Test("local package errors remain available without global presentation")
    func localPackageErrors() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let delegate = ErrorDelegate()
            harness.owner.delegate = delegate
            let pending = Task { await harness.owner.load(target: .global, surfaceError: false) }
            try await harness.socket.waitUntilSent(count: 2)
            let requestValue = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(failure(id: requestValue.id, message: "local failure"))
            #expect(!(await pending.value))
            #expect(harness.owner.error(for: .global) == "local failure")
            #expect(delegate.messages.isEmpty)
            await harness.client.close()
        }
    }

    @Test("typed mutations preserve exact wire values and update only the admitted target")
    func typedMutationEffects() async throws {
        try await runScenario {
            let harness = try await makeHarness(commandIDs: ["00000000-0000-0000-0000-000000000091"])
            let target = PackageConfigurationTarget.workspace(cwd: "/workspace/project")
            harness.owner.installHostedUpdates([
                update("remove-me", scope: .project),
                update("keep-me", scope: .project),
            ], for: target)
            harness.owner.installHostedUpdates([update("global", scope: .user)], for: .global)

            let mutation = Task {
                try await harness.owner.mutate(.remove, source: "remove-me", local: true, target: target)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let requestValue = try request(await harness.socket.sentFrames()[1])
            #expect(requestValue.method == "packages.remove")
            #expect(requestValue.params?["source"] == .string("remove-me"))
            #expect(requestValue.params?["local"] == .bool(true))
            #expect(requestValue.params?["cwd"] == .string("/workspace/project"))
            #expect(requestValue.params?["commandId"] == .string("00000000-0000-0000-0000-000000000091"))
            await harness.socket.enqueue(response(id: requestValue.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 3)
            let reload = try request(await harness.socket.sentFrames()[2])
            #expect(reload.method == "packages.list")
            #expect(reload.params?["cwd"] == .string("/workspace/project"))
            await harness.socket.enqueue(response(id: reload.id, result: inventory("reloaded", scope: .project)))
            try await mutation.value
            #expect(harness.owner.updates(for: target).map(\.source) == ["keep-me"])
            #expect(harness.owner.updates(for: .global).map(\.source) == ["global"])
            #expect(PackageConfigurationCoordinator.mutationTimeout == .seconds(300))
            await harness.client.close()
        }
    }

    @Test("confirmed mutation reload rejects a pre-confirmation load response that arrives last")
    func mutationReloadRevokesPreConfirmationLoad() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let older = Task { await harness.owner.load(target: .global, surfaceError: false) }
            try await harness.socket.waitUntilSent(count: 2)
            let olderRequest = try request(await harness.socket.sentFrames()[1])

            let mutation = Task {
                try await harness.owner.mutate(.install, source: "package", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 3)
            let mutationRequest = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(response(id: mutationRequest.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 4)
            let reloadRequest = try request(await harness.socket.sentFrames()[3])

            await harness.socket.enqueue(response(id: reloadRequest.id, result: inventory("confirmed")))
            try await mutation.value
            await harness.socket.enqueue(response(id: olderRequest.id, result: inventory("stale")))
            #expect(!(await older.value))
            #expect(harness.owner.inventory(for: .global)?.packages.first?.source == "confirmed")
            await harness.client.close()
        }
    }

    @Test("ordinary refresh cannot supersede a confirmed mutation reload")
    func mutationReloadHasPriority() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let mutation = Task {
                try await harness.owner.mutate(.install, source: "package", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let mutationRequest = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(response(id: mutationRequest.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 3)
            let reloadRequest = try request(await harness.socket.sentFrames()[2])
            let ordinary = Task { await harness.owner.load(target: .global, surfaceError: false) }
            #expect(await ordinary.value)
            let sentCount = await harness.socket.sentFrames().count
            #expect(sentCount == 3)
            await harness.socket.enqueue(response(id: reloadRequest.id, result: inventory("confirmed")))
            try await mutation.value
            #expect(harness.owner.inventory(for: .global)?.packages.first?.source == "confirmed")
            await harness.client.close()
        }
    }

    @Test("overlapping confirmed reloads retain the newer target owner")
    func overlappingConfirmedReloadOwnership() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let older = Task {
                try await harness.owner.mutate(.install, source: "older", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let olderMutation = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(response(id: olderMutation.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 3)
            let olderReload = try request(await harness.socket.sentFrames()[2])

            let newer = Task {
                try await harness.owner.mutate(.install, source: "newer", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 4)
            let newerMutation = try request(await harness.socket.sentFrames()[3])
            await harness.socket.enqueue(response(id: newerMutation.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 5)
            let newerReload = try request(await harness.socket.sentFrames()[4])

            await harness.socket.enqueue(response(id: olderReload.id, result: inventory("stale")))
            await #expect(throws: CancellationError.self) { try await older.value }

            let ordinary = Task { await harness.owner.load(target: .global, surfaceError: false) }
            #expect(await ordinary.value)
            #expect(await harness.socket.sentFrames().count == 5)

            await harness.socket.enqueue(response(id: newerReload.id, result: inventory("newer")))
            try await newer.value
            #expect(harness.owner.inventory(for: .global)?.packages.first?.source == "newer")
            await harness.client.close()
        }
    }

    @Test("retired and superseded mutation failures become cancellation")
    func staleMutationFailuresCancel() async throws {
        try await runScenario {
            let retiredHarness = try await makeHarness()
            let retired = Task {
                try await retiredHarness.owner.mutate(.install, source: "retired", local: false, target: .global)
            }
            try await retiredHarness.socket.waitUntilSent(count: 2)
            let retiredRequest = try request(await retiredHarness.socket.sentFrames()[1])
            retiredHarness.owner.clearProfile()
            retiredHarness.owner.clearProfile()
            await retiredHarness.socket.enqueue(failure(id: retiredRequest.id, message: "retired failure"))
            await #expect(throws: CancellationError.self) { try await retired.value }
            await retiredHarness.client.close()

            let supersededHarness = try await makeHarness()
            let older = Task {
                try await supersededHarness.owner.mutate(.install, source: "older", local: false, target: .global)
            }
            try await supersededHarness.socket.waitUntilSent(count: 2)
            let olderRequest = try request(await supersededHarness.socket.sentFrames()[1])
            let newer = Task {
                try await supersededHarness.owner.mutate(.install, source: "newer", local: false, target: .global)
            }
            try await supersededHarness.socket.waitUntilSent(count: 3)
            let newerRequest = try request(await supersededHarness.socket.sentFrames()[2])
            await supersededHarness.socket.enqueue(failure(id: olderRequest.id, message: "older failure"))
            await #expect(throws: CancellationError.self) { try await older.value }
            await supersededHarness.socket.enqueue(failure(id: newerRequest.id, message: "current failure"))
            do {
                try await newer.value
                Issue.record("current package failure was hidden")
            } catch let failure as GatewayFailure {
                #expect(failure.message == "current failure")
            }
            await supersededHarness.client.close()
        }
    }

    @Test("superseded post-mutation reload errors remain silent")
    func supersededReloadErrorDoesNotSurface() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let delegate = ErrorDelegate()
            harness.owner.delegate = delegate
            let older = Task {
                try await harness.owner.mutate(.install, source: "older", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let olderMutation = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(response(id: olderMutation.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 3)
            let olderReload = try request(await harness.socket.sentFrames()[2])

            let newer = Task {
                try await harness.owner.mutate(.install, source: "newer", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 4)
            let newerMutation = try request(await harness.socket.sentFrames()[3])
            await harness.socket.enqueue(failure(id: olderReload.id, message: "stale reload failure"))
            await #expect(throws: CancellationError.self) { try await older.value }
            #expect(delegate.messages.isEmpty)
            await harness.socket.enqueue(failure(id: newerMutation.id, message: "current mutation failure"))
            await #expect(throws: GatewayFailure.self) { try await newer.value }
            #expect(delegate.messages.isEmpty)
            await harness.client.close()
        }
    }

    @Test("confirmed mutation reload revokes an in-flight update check")
    func mutationRevokesUpdateCheck() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedUpdates([update("before", scope: .user)], for: .global)
            let check = Task { await harness.owner.checkUpdates(target: .global, surfaceError: false) }
            try await harness.socket.waitUntilSent(count: 2)
            let checkRequest = try request(await harness.socket.sentFrames()[1])
            let mutation = Task {
                try await harness.owner.mutate(.install, source: "package", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 3)
            let mutationRequest = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(response(id: mutationRequest.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 4)
            let reloadRequest = try request(await harness.socket.sentFrames()[3])
            await harness.socket.enqueue(response(id: checkRequest.id, result: updates(["stale"])))
            #expect(!(await check.value))
            await harness.socket.enqueue(response(id: reloadRequest.id, result: inventory("confirmed")))
            try await mutation.value
            #expect(harness.owner.updates(for: .global).map(\.source) == ["before"])
            await harness.client.close()
        }
    }

    @Test("update markers remain unchanged until mutation confirmation")
    func markerConfirmationBoundary() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedUpdates([
                update("update-me", scope: .user),
                update("update-me", scope: .project),
                update("keep-me", scope: .user),
            ], for: .global)
            let mutation = Task {
                try await harness.owner.mutate(.update, source: "update-me", local: false, target: .global)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let pending = try request(await harness.socket.sentFrames()[1])
            #expect(harness.owner.updates(for: .global).map(\.id) == ["user:update-me", "project:update-me", "user:keep-me"])
            await harness.socket.enqueue(response(id: pending.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 3)
            #expect(harness.owner.updates(for: .global).map(\.id) == ["project:update-me", "user:keep-me"])
            let reload = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(response(id: reload.id, result: inventory("updated")))
            try await mutation.value
            await harness.client.close()
        }
    }

    @Test("retired receipt uncertainty cancels while same-profile uncertainty remains explicit")
    func receiptUncertaintyAdmission() async throws {
        try await runScenario {
            let retiredClock = ManualClock()
            let retiredHarness = try await makeHarness(clock: retiredClock.clock)
            let retired = Task {
                try await retiredHarness.owner.mutate(.install, source: "retired", local: false, target: .global)
            }
            try await retiredClock.expireRequest(on: retiredHarness.socket, sentCount: 2, after: .seconds(300))
            try await retiredHarness.socket.waitUntilSent(count: 3)
            let status = try request(await retiredHarness.socket.sentFrames()[2])
            #expect(status.method == "command.status")
            retiredHarness.owner.clearProfile()
            retiredHarness.owner.clearProfile()
            await retiredHarness.lifecycle.teardown()
            await #expect(throws: CancellationError.self) { try await retired.value }

            let currentClock = ManualClock()
            let currentHarness = try await makeHarness(clock: currentClock.clock)
            let current = Task {
                try await currentHarness.owner.mutate(.install, source: "current", local: false, target: .global)
            }
            try await currentClock.expireRequest(on: currentHarness.socket, sentCount: 2, after: .seconds(300))
            try await currentHarness.socket.waitUntilSent(count: 3)
            let currentStatus = try request(await currentHarness.socket.sentFrames()[2])
            #expect(currentStatus.method == "command.status")
            current.cancel()
            do {
                try await current.value
                Issue.record("same-profile uncertain outcome was hidden")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
            }
            await currentHarness.client.close()
        }
    }

    @Test("possibly-sent package mutation replays with one stable command ID")
    func receiptResolution() async throws {
        try await runScenario {
            let clock = ManualClock()
            let harness = try await makeHarness(commandIDs: ["00000000-0000-0000-0000-000000000092"], clock: clock.clock)
            let mutation = Task {
                try await harness.owner.mutate(.install, source: "package", local: false, target: .global)
            }
            try await clock.expireRequest(on: harness.socket, sentCount: 2, after: .seconds(300))
            try await harness.socket.waitUntilSent(count: 3)
            let status = try request(await harness.socket.sentFrames()[2])
            #expect(status.method == "command.status")
            #expect(status.params?["method"] == .string("packages.install"))
            #expect(status.params?["commandId"] == .string("00000000-0000-0000-0000-000000000092"))
            await harness.socket.enqueue(response(id: status.id, result: .object(["status": .string("missing")])))
            try await harness.socket.waitUntilSent(count: 4)
            let replay = try request(await harness.socket.sentFrames()[3])
            #expect(replay.method == "packages.install")
            #expect(replay.params?["commandId"] == status.params?["commandId"])
            await harness.socket.enqueue(response(id: replay.id, result: .object([:])))
            try await harness.socket.waitUntilSent(count: 5)
            let reload = try request(await harness.socket.sentFrames()[4])
            await harness.socket.enqueue(response(id: reload.id, result: inventory("confirmed")))
            try await mutation.value
            await harness.client.close()
        }
    }

    @Test("AppModel observes nested package projections")
    func nestedObservation() {
        let model = AppModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.packageInventory(for: .global)
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.installHostedPackageInventory(
            PackageInventory(packages: [], resources: .object([:])),
            for: .global
        )
        #expect(changed.withLock { $0 })
    }

    private final class ErrorDelegate: PackageConfigurationCoordinatorDelegate {
        var messages: [String] = []
        func packageConfigurationCoordinatorSurface(_ error: Error) {
            messages.append(error.localizedDescription)
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let lifecycle: GatewayLifecycleCoordinator
        let owner: PackageConfigurationCoordinator
    }

    private struct Request {
        let id: String
        let method: String
        let params: [String: JSONValue]?
    }

    private func runScenario(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        let task = Task { @MainActor in try await operation() }
        defer { task.cancel() }
        try await withTestWatchdog { try await valueOfOwnedTask(task) }
    }

    private func makeHarness(commandIDs: [String] = [], clock: MonotonicClock = .continuous) async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock)
        let lifecycle = makeLifecycle(client: client)
        let executor = ConfirmedMutationExecutor(
            client: client,
            lifecycle: lifecycle,
            clock: .continuous,
            performanceSignposts: RecordingPerformanceSignposts()
        )
        let uuids = commandIDs.compactMap(UUID.init(uuidString:))
        let owner = PackageConfigurationCoordinator(
            client: client,
            mutationExecutor: executor,
            uuidSource: uuids.isEmpty ? .random : SequenceUUIDSource(uuids).source
        )
        await socket.enqueue(helloFrame())
        try await lifecycle.connectHosted(profile: profile, token: "token")
        return Harness(socket: socket, client: client, lifecycle: lifecycle, owner: owner)
    }

    private func makeLifecycle(client: GatewayClient) -> GatewayLifecycleCoordinator {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return GatewayLifecycleCoordinator(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
    }

    private func request(_ data: Data) throws -> Request {
        let object = try #require(JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue),
            params: object["params"]?.objectValue
        )
    }

    private func inventory(_ source: String, scope: PackageSummary.Scope = .user) -> JSONValue {
        .object([
            "packages": .array([.object([
                "source": .string(source),
                "scope": .string(scope.rawValue),
                "filtered": .bool(false),
                "installedPath": .null,
            ])]),
            "resources": .object([
                "extensions": .array([]),
                "skills": .array([]),
                "prompts": .array([]),
                "themes": .array([]),
            ]),
        ])
    }

    private func update(_ source: String, scope: PackageSummary.Scope) -> PackageUpdate {
        PackageUpdate(source: source, displayName: source, type: "npm", scope: scope)
    }

    private func updates(_ sources: [String]) -> JSONValue {
        .object(["updates": .array(sources.map { source in
            .object([
                "source": .string(source),
                "displayName": .string(source),
                "type": .string("npm"),
                "scope": .string("user"),
            ])
        })])
    }

    private func response(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func failure(id: String, message: String) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string("synthetic"),
                "message": .string(message),
                "retryable": .bool(false),
            ]),
        ]))
    }

    private var profile: GatewayProfile {
        GatewayProfile(id: "machine", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","restart-drain.v1","restart-supervised.v1"]}"#.utf8)
    }
}

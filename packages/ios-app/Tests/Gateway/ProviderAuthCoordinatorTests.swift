import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Provider authentication coordinator")
struct ProviderAuthCoordinatorTests {
    @Test("target catalogs are isolated, publish atomically, and newest same-target reads win")
    func targetAdmissionAndAtomicPublication() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let session = ProviderCatalogTarget.session(id: "session-a")

            let global = Task { await harness.owner.refreshCatalog(target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let sessionLoad = Task { await harness.owner.refreshCatalog(target: session) }
            try await harness.socket.waitUntilSent(count: 5)

            let sessionRequests = try await requests(in: 3...4, socket: harness.socket)
            #expect(sessionRequests.allSatisfy { $0.params?["sessionId"] == .string("session-a") })
            try await respondCatalog(sessionRequests, marker: "session", socket: harness.socket)
            #expect(await sessionLoad.value)
            #expect(harness.owner.catalog(for: session)?.providers.first?.id == "session")
            #expect(harness.owner.catalog(for: .global) == nil)

            let globalRequests = try await requests(in: 1...2, socket: harness.socket)
            let modelRequest = try #require(globalRequests.first { $0.method == "model.list" })
            let providerRequest = try #require(globalRequests.first { $0.method == "provider.list" })
            await harness.socket.enqueue(response(id: modelRequest.id, result: modelResult("global")))
            await Task.yield()
            #expect(harness.owner.catalog(for: .global) == nil)
            await harness.socket.enqueue(response(id: providerRequest.id, result: providerResult("global")))
            #expect(await global.value)
            #expect(harness.owner.catalog(for: .global)?.models.first?.id == "global-model")

            let older = Task { await harness.owner.refreshCatalog(target: .global) }
            try await harness.socket.waitUntilSent(count: 7)
            let newer = Task { await harness.owner.refreshCatalog(target: .global) }
            try await harness.socket.waitUntilSent(count: 9)
            try await respondCatalog(
                requests(in: 7...8, socket: harness.socket),
                marker: "newer",
                socket: harness.socket
            )
            #expect(await newer.value)
            try await respondCatalog(
                requests(in: 5...6, socket: harness.socket),
                marker: "older",
                socket: harness.socket
            )
            #expect(!(await older.value))
            #expect(harness.owner.catalog(for: .global)?.providers.first?.id == "newer")
            await harness.client.close()
        }
    }

    @Test("repeated model cursors reject the complete catalog without partial publication")
    func repeatedCursorRejected() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let load = Task { await harness.owner.refreshCatalog(target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let first = try await requests(in: 1...2, socket: harness.socket)
            let provider = try #require(first.first { $0.method == "provider.list" })
            let model = try #require(first.first { $0.method == "model.list" })
            await harness.socket.enqueue(response(id: provider.id, result: providerResult("provider")))
            await harness.socket.enqueue(response(id: model.id, result: modelResult("page-1", nextCursor: "again")))
            try await harness.socket.waitUntilSent(count: 4)
            let second = try request(await harness.socket.sentFrames()[3])
            #expect(second.params?["cursor"] == .string("again"))
            await harness.socket.enqueue(response(id: second.id, result: modelResult("page-2", nextCursor: "again")))
            #expect(!(await load.value))
            #expect(harness.owner.catalog(for: .global) == nil)
            #expect(harness.delegate.errors == ["Tron returned a repeated model cursor."])
            await harness.client.close()
        }
    }

    @Test("profile clear rejects parallel catalog responses and later pagination")
    func profileClearRejectsCatalogBoundaries() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let parallel = Task { await harness.owner.refreshCatalog(target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let pending = try await requests(in: 1...2, socket: harness.socket)
            harness.owner.clearProfile()
            try await respondCatalog(pending, marker: "retired", socket: harness.socket)
            #expect(!(await parallel.value))
            #expect(harness.owner.catalog(for: .global) == nil)

            let paged = Task { await harness.owner.refreshCatalog(target: .global) }
            try await harness.socket.waitUntilSent(count: 5)
            let firstPage = try await requests(in: 3...4, socket: harness.socket)
            let provider = try #require(firstPage.first { $0.method == "provider.list" })
            let model = try #require(firstPage.first { $0.method == "model.list" })
            await harness.socket.enqueue(response(id: provider.id, result: providerResult("retired-page")))
            await harness.socket.enqueue(response(id: model.id, result: modelResult("page-1", nextCursor: "page-2")))
            try await harness.socket.waitUntilSent(count: 6)
            let secondPage = try request(await harness.socket.sentFrames()[5])
            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: secondPage.id, result: modelResult("page-2")))
            #expect(!(await paged.value))
            #expect(harness.owner.catalog(for: .global) == nil)
            #expect(harness.delegate.errors.isEmpty)
            await harness.client.close()
        }
    }

    @Test("auth target survives prompts and drives exact completion refresh")
    func authTargetRetainedThroughCompletion() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let target = ProviderCatalogTarget.session(id: "session-a")
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: target)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let beginRequest = try request(await harness.socket.sentFrames()[1])
            #expect(beginRequest.method == "auth.begin")
            #expect(beginRequest.params?["sessionId"] == .string("session-a"))
            await harness.socket.enqueue(response(id: beginRequest.id, result: .object(["operationId": .string("operation-a")])))
            try await begin.value

            harness.owner.handlePrompt(promptPayload(operation: "operation-a", prompt: "prompt-a"))
            #expect(harness.owner.prompt?.id == "prompt-a")
            #expect(harness.owner.hostedTarget(for: "operation-a") == target)

            let completion = Task {
                await harness.owner.handleCompletion(.object([
                    "operationId": .string("operation-a"),
                    "success": .bool(true),
                ]))
            }
            try await harness.socket.waitUntilSent(count: 4)
            let catalogRequests = try await requests(in: 2...3, socket: harness.socket)
            #expect(catalogRequests.allSatisfy { $0.params?["sessionId"] == .string("session-a") })
            try await respondCatalog(catalogRequests, marker: "authenticated", socket: harness.socket)
            await completion.value
            #expect(harness.owner.prompt == nil)
            #expect(harness.owner.hostedTarget(for: "operation-a") == nil)
            #expect(harness.owner.catalog(for: target)?.providers.first?.id == "authenticated")
            await harness.client.close()
        }
    }

    @Test("prompt and event emitted before begin response promote together")
    func preResponsePresentationPromotes() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: .global)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])

            harness.owner.handleEvent(.object([
                "operationId": .string("operation"),
                "event": .object(["type": .string("info"), "message": .string("Pre-response event")]),
            ]))
            harness.owner.handlePrompt(promptPayload(operation: "operation", prompt: "pre-response-prompt"))
            #expect(harness.owner.prompt == nil)
            #expect(harness.owner.event == nil)
            #expect(harness.owner.hostedQuarantinedOperationCount == 1)

            await harness.socket.enqueue(response(
                id: request.id,
                result: .object(["operationId": .string("operation")])
            ))
            try await begin.value

            #expect(harness.owner.prompt?.id == "pre-response-prompt")
            #expect(harness.owner.event?.kind == .info)
            #expect(harness.owner.event?.message == "Pre-response event")
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            await harness.client.close()
        }
    }

    @Test("completion before begin response refreshes the admitted exact target")
    func preResponseCompletionIsProcessed() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let target = ProviderCatalogTarget.session(id: "session-a")
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: target)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])

            await harness.owner.handleCompletion(.object([
                "operationId": .string("operation"),
                "success": .bool(true),
            ]))
            #expect(harness.owner.hostedQuarantinedOperationCount == 1)
            await harness.socket.enqueue(response(
                id: request.id,
                result: .object(["operationId": .string("operation")])
            ))

            try await harness.socket.waitUntilSent(count: 4)
            let catalogRequests = try await requests(in: 2...3, socket: harness.socket)
            #expect(catalogRequests.allSatisfy { $0.params?["sessionId"] == .string("session-a") })
            try await respondCatalog(catalogRequests, marker: "completed", socket: harness.socket)
            try await begin.value

            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.hostedActiveAuthOperationID == nil)
            #expect(harness.owner.hostedTarget(for: "operation") == nil)
            #expect(harness.owner.catalog(for: target)?.providers.first?.id == "completed")
            await harness.client.close()
        }
    }

    @Test("profile clear revokes pre-response completion refresh")
    func profileClearRevokesPreResponseCompletionRefresh() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: .global)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])
            await harness.owner.handleCompletion(.object([
                "operationId": .string("operation"),
                "success": .bool(false),
                "error": .string("retired failure"),
            ]))
            await harness.socket.enqueue(response(
                id: request.id,
                result: .object(["operationId": .string("operation")])
            ))
            try await harness.socket.waitUntilSent(count: 4)
            let catalogRequests = try await requests(in: 2...3, socket: harness.socket)

            harness.owner.clearProfile()
            try await respondCatalog(catalogRequests, marker: "retired", socket: harness.socket)
            do {
                try await begin.value
                Issue.record("Retired pre-response completion unexpectedly completed begin admission")
            } catch is CancellationError {}

            #expect(harness.owner.catalog(for: .global) == nil)
            #expect(harness.delegate.completionErrors.isEmpty)
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            await harness.client.close()
        }
    }

    @Test("aggregate quarantine element limit evicts the oldest operation and promotes the admitted newest payload")
    func aggregateQuarantineElementLimit() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: .global)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])

            for index in 0..<4 {
                harness.owner.handleEvent(authEventPayload(
                    operation: "operation-\(index)",
                    message: "event-\(index)",
                    linkCount: 15
                ))
            }
            #expect(harness.owner.hostedQuarantinedOperationCount == 4)
            #expect(harness.owner.hostedQuarantinedElementCount == 64)
            #expect(harness.owner.hostedQuarantinedOperationIDs == [
                "operation-0", "operation-1", "operation-2", "operation-3",
            ])

            harness.owner.handlePrompt(promptPayload(operation: "operation-3", prompt: "matching-prompt"))
            #expect(harness.owner.hostedQuarantinedOperationIDs == [
                "operation-1", "operation-2", "operation-3",
            ])
            #expect(harness.owner.hostedQuarantinedElementCount <= 64)
            #expect(harness.owner.hostedQuarantinedByteCount <= 16 * 1_024)

            await harness.socket.enqueue(response(
                id: request.id,
                result: .object(["operationId": .string("operation-3")])
            ))
            try await begin.value

            #expect(harness.owner.prompt?.id == "matching-prompt")
            #expect(harness.owner.event?.message == "event-3")
            #expect(harness.owner.event?.links.count == 15)
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.hostedQuarantinedElementCount == 0)
            await harness.client.close()
        }
    }

    @Test("aggregate quarantine byte limit evicts the oldest operation and promotes the admitted newest payload")
    func aggregateQuarantineByteLimit() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: .global)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])
            let retainedMessage = String(repeating: "x", count: 4_200)

            for index in 0..<4 {
                harness.owner.handleEvent(authEventPayload(
                    operation: "operation-\(index)",
                    message: "\(index)\(retainedMessage)"
                ))
            }
            #expect(harness.owner.hostedQuarantinedOperationIDs == [
                "operation-1", "operation-2", "operation-3",
            ])
            #expect(harness.owner.hostedQuarantinedOperationCount == 3)
            #expect(harness.owner.hostedQuarantinedElementCount == 3)
            #expect(harness.owner.hostedQuarantinedByteCount <= 16 * 1_024)

            await harness.socket.enqueue(response(
                id: request.id,
                result: .object(["operationId": .string("operation-3")])
            ))
            try await begin.value

            #expect(harness.owner.event?.message == "3\(retainedMessage)")
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.hostedQuarantinedElementCount == 0)
            #expect(harness.owner.hostedQuarantinedByteCount == 0)
            await harness.client.close()
        }
    }

    @Test("failed begins bound and dispose pre-response quarantine")
    func failedBeginDisposesBoundedQuarantine() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: .global)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])

            for index in 0..<6 {
                harness.owner.handleEvent(authEventPayload(operation: "operation-\(index)"))
            }
            harness.owner.handleEvent(.object([
                "operationId": .string("oversized"),
                "event": .object([
                    "type": .string("info"),
                    "message": .string(String(repeating: "x", count: 20 * 1_024)),
                ]),
            ]))
            #expect(harness.owner.hostedQuarantinedOperationCount == 4)
            #expect(harness.owner.hostedQuarantinedByteCount <= 16 * 1_024)

            await harness.socket.enqueue(errorResponse(
                id: request.id,
                code: "auth_failed",
                message: "Synthetic failure"
            ))
            do {
                try await begin.value
                Issue.record("Failed auth begin unexpectedly succeeded")
            } catch is GatewayFailure {}
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.hostedQuarantinedByteCount == 0)

            let cancelledBegin = Task {
                try await harness.owner.beginAuth(providerID: "cancelled", authType: "api_key", target: .global)
            }
            try await harness.socket.waitUntilSent(count: 3)
            harness.owner.handlePrompt(promptPayload(operation: "cancelled-operation", prompt: "prompt"))
            #expect(harness.owner.hostedQuarantinedOperationCount == 1)
            cancelledBegin.cancel()
            do {
                try await cancelledBegin.value
                Issue.record("Cancelled auth begin unexpectedly succeeded")
            } catch {}
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.hostedQuarantinedByteCount == 0)

            harness.owner.handlePrompt(promptPayload(operation: "unsolicited", prompt: "prompt"))
            harness.owner.handleEvent(authEventPayload(operation: "unsolicited"))
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.prompt == nil)
            #expect(harness.owner.event == nil)
            await harness.client.close()
        }
    }

    @Test("stale responses and cancellations cannot clear newer auth state")
    func staleAuthWorkCannotClearNewerState() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedAuthOperation("old", target: .global)
            harness.owner.handlePrompt(promptPayload(operation: "old", prompt: "old-prompt"))
            let answer = Task { try await harness.owner.answerAuth("secret") }
            try await harness.socket.waitUntilSent(count: 2)
            let answerRequest = try request(await harness.socket.sentFrames()[1])
            harness.owner.installHostedAuthOperation("new", target: .global)
            harness.owner.handlePrompt(promptPayload(operation: "new", prompt: "new-prompt"))
            await harness.socket.enqueue(response(id: answerRequest.id, result: .object(["answered": .bool(true)])))
            try await answer.value
            #expect(harness.owner.prompt?.operationId == "new")

            harness.owner.handleEvent(authEventPayload(operation: "new"))
            let cancel = Task { await harness.owner.cancelAuth(operationID: "old") }
            try await harness.socket.waitUntilSent(count: 3)
            let cancelRequest = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(response(id: cancelRequest.id, result: .object(["cancelled": .bool(true)])))
            await cancel.value
            #expect(harness.owner.prompt?.operationId == "new")
            #expect(harness.owner.event?.operationId == "new")

            let staleCompletion = Task {
                await harness.owner.handleCompletion(.object([
                    "operationId": .string("old"),
                    "success": .bool(true),
                ]))
            }
            await staleCompletion.value
            #expect(harness.owner.prompt?.operationId == "new")
            #expect(harness.owner.event?.operationId == "new")
            await harness.client.close()
        }
    }

    @Test("older completion refreshes only its retained target and preserves newer auth state")
    func olderCompletionCannotRefreshNewerTarget() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let olderTarget = ProviderCatalogTarget.session(id: "session-old")
            let newerTarget = ProviderCatalogTarget.session(id: "session-new")

            let olderBegin = Task {
                try await harness.owner.beginAuth(providerID: "old", authType: "api_key", target: olderTarget)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let olderRequest = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(response(id: olderRequest.id, result: .object(["operationId": .string("operation-old")])))
            try await olderBegin.value

            let newerBegin = Task {
                try await harness.owner.beginAuth(providerID: "new", authType: "api_key", target: newerTarget)
            }
            try await harness.socket.waitUntilSent(count: 3)
            let newerRequest = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(response(id: newerRequest.id, result: .object(["operationId": .string("operation-new")])))
            try await newerBegin.value
            harness.owner.handlePrompt(promptPayload(operation: "operation-new", prompt: "new-prompt"))
            harness.owner.handleEvent(authEventPayload(operation: "operation-new"))

            let completion = Task {
                await harness.owner.handleCompletion(.object([
                    "operationId": .string("operation-old"),
                    "success": .bool(true),
                ]))
            }
            try await harness.socket.waitUntilSent(count: 5)
            let catalogRequests = try await requests(in: 3...4, socket: harness.socket)
            #expect(catalogRequests.allSatisfy { $0.params?["sessionId"] == .string("session-old") })
            try await respondCatalog(catalogRequests, marker: "old-refreshed", socket: harness.socket)
            await completion.value

            #expect(harness.owner.prompt?.operationId == "operation-new")
            #expect(harness.owner.event?.operationId == "operation-new")
            #expect(harness.owner.hostedTarget(for: "operation-new") == newerTarget)
            #expect(harness.owner.catalog(for: olderTarget)?.providers.first?.id == "old-refreshed")
            #expect(harness.owner.catalog(for: newerTarget) == nil)
            await harness.client.close()
        }
    }

    @Test("reversed concurrent begins and old notifications preserve the newest operation")
    func newestBeginAndNotificationAdmission() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let oldTarget = ProviderCatalogTarget.session(id: "old-target")
            let newTarget = ProviderCatalogTarget.session(id: "new-target")
            let old = Task {
                try await harness.owner.beginAuth(providerID: "old", authType: "api_key", target: oldTarget)
            }
            defer { old.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let oldRequest = try request(await harness.socket.sentFrames()[1])
            let new = Task {
                try await harness.owner.beginAuth(providerID: "new", authType: "api_key", target: newTarget)
            }
            defer { new.cancel() }
            try await harness.socket.waitUntilSent(count: 3)
            let newRequest = try request(await harness.socket.sentFrames()[2])

            harness.owner.handlePrompt(promptPayload(operation: "old-operation", prompt: "old-pre-response"))
            harness.owner.handleEvent(.object([
                "operationId": .string("old-operation"),
                "event": .object(["type": .string("info"), "message": .string("old pre-response")]),
            ]))
            harness.owner.handlePrompt(promptPayload(operation: "new-operation", prompt: "new-pre-response"))
            harness.owner.handleEvent(.object([
                "operationId": .string("new-operation"),
                "event": .object(["type": .string("info"), "message": .string("new pre-response")]),
            ]))
            #expect(harness.owner.hostedQuarantinedOperationCount == 2)

            await harness.socket.enqueue(response(
                id: newRequest.id,
                result: .object(["operationId": .string("new-operation")])
            ))
            try await new.value
            #expect(harness.owner.prompt?.id == "new-pre-response")
            #expect(harness.owner.event?.message == "new pre-response")
            await harness.socket.enqueue(response(
                id: oldRequest.id,
                result: .object(["operationId": .string("old-operation")])
            ))
            do {
                try await old.value
                Issue.record("Older reversed auth begin unexpectedly replaced the newer operation")
            } catch is CancellationError {}

            #expect(harness.owner.hostedActiveAuthOperationID == "new-operation")
            #expect(harness.owner.hostedTarget(for: "old-operation") == oldTarget)
            #expect(harness.owner.hostedTarget(for: "new-operation") == newTarget)
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            harness.owner.handlePrompt(promptPayload(operation: "new-operation", prompt: "new-prompt"))
            harness.owner.handleEvent(authEventPayload(operation: "new-operation"))
            harness.owner.handlePrompt(promptPayload(operation: "old-operation", prompt: "old-prompt"))
            harness.owner.handleEvent(.object([
                "operationId": .string("old-operation"),
                "event": .object(["type": .string("info"), "message": .string("old")]),
            ]))
            #expect(harness.owner.prompt?.operationId == "new-operation")
            #expect(harness.owner.prompt?.id == "new-prompt")
            #expect(harness.owner.event?.operationId == "new-operation")
            #expect(harness.owner.event?.kind == .progress)
            await harness.client.close()
        }
    }

    @Test("profile clear during completion refresh suppresses the retired failure")
    func completionProfileRetirement() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedAuthOperation("operation", target: .global)
            harness.owner.handlePrompt(promptPayload(operation: "operation", prompt: "prompt"))
            let completion = Task {
                await harness.owner.handleCompletion(.object([
                    "operationId": .string("operation"),
                    "success": .bool(false),
                    "error": .string("retired failure"),
                ]))
            }
            defer { completion.cancel() }
            try await harness.socket.waitUntilSent(count: 3)
            let requests = try await requests(in: 1...2, socket: harness.socket)
            harness.owner.clearProfile()
            try await respondCatalog(requests, marker: "retired", socket: harness.socket)
            await completion.value

            #expect(harness.delegate.completionErrors.isEmpty)
            #expect(harness.owner.catalog(for: .global) == nil)
            #expect(harness.owner.prompt == nil)
            #expect(harness.owner.event == nil)
            await harness.client.close()
        }
    }

    @Test("a newer begin during an older completion refresh suppresses the older error")
    func newerBeginSuppressesSuspendedCompletionError() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let oldTarget = ProviderCatalogTarget.session(id: "old-target")
            let newTarget = ProviderCatalogTarget.session(id: "new-target")
            harness.owner.installHostedAuthOperation("old-operation", target: oldTarget)
            let completion = Task {
                await harness.owner.handleCompletion(.object([
                    "operationId": .string("old-operation"),
                    "success": .bool(false),
                    "error": .string("old failure"),
                ]))
            }
            defer { completion.cancel() }
            try await harness.socket.waitUntilSent(count: 3)
            let catalogRequests = try await requests(in: 1...2, socket: harness.socket)

            let begin = Task {
                try await harness.owner.beginAuth(providerID: "new", authType: "api_key", target: newTarget)
            }
            defer { begin.cancel() }
            try await harness.socket.waitUntilSent(count: 4)
            let beginRequest = try request(await harness.socket.sentFrames()[3])
            await harness.socket.enqueue(response(
                id: beginRequest.id,
                result: .object(["operationId": .string("new-operation")])
            ))
            try await begin.value
            try await respondCatalog(catalogRequests, marker: "old-refreshed", socket: harness.socket)
            await completion.value

            #expect(harness.delegate.completionErrors.isEmpty)
            #expect(harness.owner.hostedActiveAuthOperationID == "new-operation")
            #expect(harness.owner.event?.operationId == "new-operation")
            #expect(harness.owner.catalog(for: oldTarget)?.providers.first?.id == "old-refreshed")
            await harness.client.close()
        }
    }

    @Test("auth payload parsers preserve supported prompt and event contracts")
    func parserCompatibility() async {
        let owner = makeDisconnectedOwner()
        owner.installHostedAuthOperation("operation", target: .global)

        owner.handlePrompt(.object([
            "operationId": .string("operation"),
            "promptId": .string("text"),
            "prompt": .object([
                "type": .string("text"),
                "message": .string("Text prompt"),
                "placeholder": .string("Value"),
            ]),
        ]))
        #expect(owner.prompt?.kind == .text)
        #expect(owner.prompt?.placeholder == "Value")

        owner.handlePrompt(.object([
            "operationId": .string("operation"),
            "promptId": .string("select"),
            "prompt": .object([
                "type": .string("select"),
                "message": .string("Choose"),
                "options": .array([.object([
                    "id": .string("choice"),
                    "label": .string("Choice"),
                    "description": .string("Description"),
                ])]),
            ]),
        ]))
        #expect(owner.prompt?.kind == .select)
        #expect(owner.prompt?.options.first?.id == "choice")
        #expect(owner.prompt?.options.first?.description == "Description")

        owner.handlePrompt(.object([
            "operationId": .string("operation"),
            "promptId": .string("manual"),
            "prompt": .object([
                "type": .string("manual_code"),
                "message": .string("Paste code"),
            ]),
        ]))
        #expect(owner.prompt?.kind == .manualCode)

        owner.handleEvent(.object([
            "operationId": .string("operation"),
            "event": .object([
                "type": .string("info"),
                "message": .string("Information"),
                "links": .array([.object([
                    "url": .string("https://example.com/info"),
                    "label": .string("Details"),
                ])]),
            ]),
        ]))
        #expect(owner.event?.kind == .info)
        #expect(owner.event?.links.first?.label == "Details")

        owner.handleEvent(.object([
            "operationId": .string("operation"),
            "event": .object([
                "type": .string("auth_url"),
                "url": .string("https://example.com/login"),
                "instructions": .string("Open the link"),
            ]),
        ]))
        #expect(owner.event?.kind == .authURL)
        #expect(owner.event?.url?.absoluteString == "https://example.com/login")
        #expect(owner.event?.instructions == "Open the link")
    }

    @Test("profile clear rejects suspended auth admission")
    func profileClearRejectsAuthWork() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let begin = Task {
                try await harness.owner.beginAuth(providerID: "provider", authType: "api_key", target: .global)
            }
            try await harness.socket.waitUntilSent(count: 2)
            let request = try request(await harness.socket.sentFrames()[1])
            harness.owner.handlePrompt(promptPayload(operation: "late", prompt: "pre-response"))
            harness.owner.handleEvent(authEventPayload(operation: "late"))
            #expect(harness.owner.hostedQuarantinedOperationCount == 1)
            harness.owner.clearProfile()
            #expect(harness.owner.hostedQuarantinedOperationCount == 0)
            #expect(harness.owner.hostedQuarantinedByteCount == 0)
            await harness.socket.enqueue(response(id: request.id, result: .object(["operationId": .string("late")])))
            do {
                try await begin.value
                Issue.record("Retired auth begin unexpectedly succeeded")
            } catch is CancellationError {}
            #expect(harness.owner.event == nil)
            #expect(harness.owner.hostedTarget(for: "late") == nil)
            await harness.client.close()
        }
    }

    @Test("profile clear revokes suspended answer and cancel work")
    func profileClearRejectsAnswerAndCancel() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedAuthOperation("answer-operation", target: .global)
            harness.owner.handlePrompt(promptPayload(operation: "answer-operation", prompt: "prompt"))
            let answer = Task { try await harness.owner.answerAuth("secret") }
            defer { answer.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let answerRequest = try request(await harness.socket.sentFrames()[1])
            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: answerRequest.id, result: .object(["answered": .bool(true)])))
            do {
                try await answer.value
                Issue.record("Retired auth answer unexpectedly succeeded")
            } catch is CancellationError {}
            #expect(harness.owner.prompt == nil)
            #expect(harness.owner.hostedActiveAuthOperationID == nil)

            harness.owner.installHostedAuthOperation("cancel-operation", target: .global)
            harness.owner.handleEvent(authEventPayload(operation: "cancel-operation"))
            let cancel = Task { await harness.owner.cancelAuth() }
            defer { cancel.cancel() }
            try await harness.socket.waitUntilSent(count: 3)
            let cancelRequest = try request(await harness.socket.sentFrames()[2])
            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: cancelRequest.id, result: .object(["cancelled": .bool(true)])))
            await cancel.value
            #expect(harness.owner.event == nil)
            #expect(harness.owner.hostedActiveAuthOperationID == nil)
            #expect(harness.owner.hostedTarget(for: "cancel-operation") == nil)
            await harness.client.close()
        }
    }

    @Test("profile clear revokes forced refresh and logout after mutation confirmation")
    func profileClearRejectsProviderMutations() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let refresh = Task { try await harness.owner.refreshModelCatalog(target: .global) }
            defer { refresh.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let refreshRequest = try request(await harness.socket.sentFrames()[1])
            #expect(refreshRequest.method == "models.refresh")
            harness.owner.clearProfile()
            await harness.socket.enqueue(response(
                id: refreshRequest.id,
                result: .object(["refreshed": .bool(true)])
            ))
            do {
                try await refresh.value
                Issue.record("Retired model refresh unexpectedly succeeded")
            } catch is CancellationError {}
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(harness.owner.catalog(for: .global) == nil)

            let logout = Task { try await harness.owner.logout(providerID: "provider", target: .global) }
            defer { logout.cancel() }
            try await harness.socket.waitUntilSent(count: 3)
            let logoutRequest = try request(await harness.socket.sentFrames()[2])
            #expect(logoutRequest.method == "auth.logout")
            harness.owner.clearProfile()
            await harness.socket.enqueue(response(
                id: logoutRequest.id,
                result: .object(["loggedOut": .bool(true)])
            ))
            do {
                try await logout.value
                Issue.record("Retired logout unexpectedly succeeded")
            } catch is CancellationError {}
            #expect(await harness.socket.sentFrames().count == 3)
            #expect(harness.owner.catalog(for: .global) == nil)
            await harness.client.close()
        }
    }

    @Test("forced model refresh uses shared receipts and refreshes its exact target")
    func modelRefreshUsesReceipts() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let target = ProviderCatalogTarget.session(id: "session-a")
            await harness.socket.failNextSend(possiblySentFailure())
            let mutation = Task { try await harness.owner.refreshModelCatalog(target: target, force: false) }
            try await completeReceiptMutation(
                method: "models.refresh",
                target: target,
                result: .object(["refreshed": .bool(true)]),
                startingAt: 1,
                harness: harness
            )
            try await mutation.value
            #expect(harness.owner.catalog(for: target)?.providers.first?.id == "confirmed")
            await harness.client.close()
        }
    }

    @Test("logout uses shared receipts and refreshes its exact target")
    func logoutUsesReceipts() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let target = ProviderCatalogTarget.session(id: "session-b")
            await harness.socket.failNextSend(possiblySentFailure())
            let mutation = Task { try await harness.owner.logout(providerID: "provider", target: target) }
            try await completeReceiptMutation(
                method: "auth.logout",
                target: target,
                result: .object(["loggedOut": .bool(true)]),
                startingAt: 1,
                harness: harness
            )
            try await mutation.value
            #expect(harness.owner.catalog(for: target)?.providers.first?.id == "confirmed")
            await harness.client.close()
        }
    }

    @Test("provider invalidation is event-only and nested observation reaches AppModel")
    func eventOnlyInvalidationAndNestedObservation() async {
        let model = AppModel()
        let observed = Mutex(false)
        withObservationTracking {
            _ = model.providerInvalidationGeneration
        } onChange: {
            observed.withLock { $0 = true }
        }
        await model.handle(GatewayEvent(type: "event", topic: "providers.changed", sessionId: nil, payload: .object([:])))
        #expect(observed.withLock { $0 })
        #expect(model.providerInvalidationGeneration == 1)

        let owner = makeDisconnectedOwner()
        owner.noteProvidersChanged()
        let generation = owner.invalidationGeneration
        owner.installHostedCatalog(ProviderCatalog(providers: [], models: []), for: .global)
        #expect(owner.invalidationGeneration == generation)
        owner.handlePrompt(promptPayload(operation: "operation", prompt: "prompt"))
        owner.handleEvent(authEventPayload(operation: "operation"))
        #expect(owner.invalidationGeneration == generation)
    }

    private func completeReceiptMutation(
        method: String,
        target: ProviderCatalogTarget,
        result: JSONValue,
        startingAt index: Int,
        harness: Harness
    ) async throws {
        try await harness.socket.waitUntilSent(count: index + 1)
        let status = try request(await harness.socket.sentFrames()[index])
        #expect(status.method == "command.status")
        #expect(status.params?["method"] == .string(method))
        let stableID = try #require(status.params?["commandId"]?.stringValue)
        await harness.socket.enqueue(response(id: status.id, result: .object(["status": .string("missing")])))

        try await harness.socket.waitUntilSent(count: index + 2)
        let replay = try request(await harness.socket.sentFrames()[index + 1])
        #expect(replay.method == method)
        #expect(replay.params?["commandId"] == .string(stableID))
        #expect(replay.params?["sessionId"] == target.sessionID.map(JSONValue.string))
        await harness.socket.enqueue(response(id: replay.id, result: result))

        try await harness.socket.waitUntilSent(count: index + 4)
        let catalogRequests = try await requests(in: (index + 2)...(index + 3), socket: harness.socket)
        #expect(catalogRequests.allSatisfy { $0.params?["sessionId"] == target.sessionID.map(JSONValue.string) })
        try await respondCatalog(catalogRequests, marker: "confirmed", socket: harness.socket)
    }

    private func runScenario(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        let scenario = Task { @MainActor in try await operation() }
        defer { scenario.cancel() }
        try await withTestWatchdog { try await valueOfOwnedTask(scenario) }
    }

    private final class Delegate: ProviderAuthCoordinatorDelegate {
        var errors: [String] = []
        var completionErrors: [String?] = []
        func providerAuthCoordinatorSurface(_ error: Error) { errors.append(error.localizedDescription) }
        func providerAuthCoordinatorSetCompletionError(_ message: String?) { completionErrors.append(message) }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let owner: ProviderAuthCoordinator
        let delegate: Delegate
    }

    private struct Request {
        let id: String
        let method: String
        let params: [String: JSONValue]?
    }

    private func makeHarness() async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
        let owner = ProviderAuthCoordinator(
            client: client,
            mutationExecutor: ConfirmedMutationExecutor(
                client: client,
                lifecycle: lifecycle,
                clock: .continuous,
                performanceSignposts: RecordingPerformanceSignposts()
            ),
            uuidSource: .random
        )
        let delegate = Delegate()
        owner.delegate = delegate
        await socket.enqueue(helloFrame())
        try await lifecycle.connectHosted(profile: profile, token: "token")
        return Harness(socket: socket, client: client, owner: owner, delegate: delegate)
    }

    private func makeDisconnectedOwner() -> ProviderAuthCoordinator {
        let client = GatewayClient()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
        return ProviderAuthCoordinator(
            client: client,
            mutationExecutor: ConfirmedMutationExecutor(
                client: client,
                lifecycle: lifecycle,
                clock: .continuous,
                performanceSignposts: RecordingPerformanceSignposts()
            ),
            uuidSource: .random
        )
    }

    private func requests(in indices: ClosedRange<Int>, socket: ScriptedGatewaySocket) async throws -> [Request] {
        let frames = await socket.sentFrames()
        return try indices.map { try request(frames[$0]) }
    }

    private func request(_ data: Data) throws -> Request {
        let object = try #require(JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue),
            params: object["params"]?.objectValue
        )
    }

    private func respondCatalog(_ requests: [Request], marker: String, socket: ScriptedGatewaySocket) async throws {
        for request in requests {
            switch request.method {
            case "provider.list":
                await socket.enqueue(response(id: request.id, result: providerResult(marker)))
            case "model.list":
                await socket.enqueue(response(id: request.id, result: modelResult(marker)))
            default:
                Issue.record("Unexpected catalog method \(request.method)")
            }
        }
    }

    private func providerResult(_ marker: String) -> JSONValue {
        .object(["providers": .array([.object([
            "id": .string(marker),
            "name": .string(marker),
            "configured": .bool(false),
            "authSource": .null,
            "credentialType": .null,
            "authMethods": .array([]),
            "modelCount": .number(1),
        ])])])
    }

    private func modelResult(_ marker: String, nextCursor: String? = nil) -> JSONValue {
        .object([
            "models": .array([.object([
                "provider": .string(marker),
                "id": .string("\(marker)-model"),
                "name": .string(marker),
                "reasoning": .bool(false),
                "input": .array([.string("text")]),
                "contextWindow": .number(4_096),
                "maxTokens": .number(1_024),
                "available": .bool(true),
            ])]),
            "nextCursor": nextCursor.map(JSONValue.string) ?? .null,
        ])
    }

    private func promptPayload(operation: String, prompt: String) -> JSONValue {
        .object([
            "operationId": .string(operation),
            "promptId": .string(prompt),
            "prompt": .object([
                "type": .string("secret"),
                "message": .string("Credential"),
            ]),
        ])
    }

    private func authEventPayload(
        operation: String,
        message: String = "Waiting",
        linkCount: Int = 0
    ) -> JSONValue {
        .object([
            "operationId": .string(operation),
            "event": .object([
                "type": .string("progress"),
                "message": .string(message),
                "links": .array((0..<linkCount).map { index in
                    .object([
                        "url": .string("https://example.test/\(operation)/\(index)"),
                        "label": .string("Link \(index)"),
                    ])
                }),
            ]),
        ])
    }

    private func response(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func errorResponse(id: String, code: String, message: String) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string(code),
                "message": .string(message),
                "retryable": .bool(false),
            ]),
        ]))
    }

    private func possiblySentFailure() -> GatewayFailure {
        GatewayFailure(code: "disconnected", message: "synthetic send failure", retryable: true, details: nil)
    }

    private var profile: GatewayProfile {
        GatewayProfile(
            id: "machine",
            label: "Mac",
            host: "gateway.test",
            port: 9_847,
            machineId: "machine",
            deviceId: "device"
        )
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }
}

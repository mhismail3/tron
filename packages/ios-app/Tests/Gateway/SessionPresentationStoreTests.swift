import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Session presentation ownership")
struct SessionPresentationStoreTests {
    private func nextAttentionRead(
        _ socket: ScriptedGatewaySocket,
        startingAt frameIndex: Int
    ) async throws -> (request: JSONValue, index: Int) {
        var index = frameIndex
        while true {
            try await socket.waitUntilSent(count: index + 1)
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
            let requestID = try #require(request.objectValue?["id"]?.stringValue)
            switch request.objectValue?["method"]?.stringValue {
            case "session.attention.read":
                return (request, index)
            case "session.commands":
                // Command readiness is an independent background request. Leave
                // it pending so this helper observes only attention ordering.
                _ = requestID
                index += 1
            default:
                Issue.record("unexpected request before attention acknowledgement")
                return (request, index)
            }
        }
    }

    private func nextRequest(
        _ method: String,
        socket: ScriptedGatewaySocket,
        startingAt frameIndex: Int
    ) async throws -> (request: JSONValue, index: Int) {
        var index = frameIndex
        while true {
            try await socket.waitUntilSent(count: index + 1)
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
            if request.objectValue?["method"]?.stringValue == method { return (request, index) }
            #expect(request.objectValue?["method"]?.stringValue == "session.commands")
            index += 1
        }
    }

    @discardableResult
    private func answerAttentionRead(
        _ socket: ScriptedGatewaySocket,
        frameIndex: Int,
        expectedRevision: Int
    ) async throws -> Int {
        let (request, index) = try await nextAttentionRead(socket, startingAt: frameIndex)
        #expect(request.objectValue?["method"]?.stringValue == "session.attention.read")
        #expect(request.objectValue?["params"]?.objectValue?["throughCompletionRevision"] == .number(Double(expectedRevision)))
        let requestID = try #require(request.objectValue?["id"]?.stringValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
            "result": .object([
                "completionRevision": .number(Double(expectedRevision)),
                "attentionRevision": .number(1),
                "isUnread": .bool(false),
            ]),
        ])))
        return index
    }

    @Test("pending presentation owns notices before first open mounts")
    func pendingPresentationOwnsNoticeScope() {
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let probe = NoticeScopeProbe(); store.delegate = probe
        let pending = SessionPresentationIdentity(sessionID: "pending", generation: 1)
        store.installHostedPresentationTargets(target: nil, pending: pending)
        store.emitHostedNoticeForTesting()
        #expect(probe.postedScopes == [.session(id: "pending", generation: 1)])
        #expect(probe.postedRoles == [.info])
    }

    @Test("successful replacement retires the previous exact scope")
    func replacementRetiresPreviousScope() {
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let probe = NoticeScopeProbe(); store.delegate = probe
        let old = SessionPresentationIdentity(sessionID: "replace", generation: 1)
        let next = SessionPresentationIdentity(sessionID: "replace", generation: 2)
        store.installHostedPresentationTargets(target: old, pending: next)
        store.mountHostedPresentationForTesting(next)
        #expect(probe.retiredScopes == [.session(id: "replace", generation: 1)])
    }

    @Test("stale close does not retire a newer pending scope")
    func staleCloseDoesNotRetireNewerPendingScope() async {
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let probe = NoticeScopeProbe(); store.delegate = probe
        let mounted = SessionPresentationIdentity(sessionID: "old", generation: 1)
        let pending = SessionPresentationIdentity(sessionID: "new", generation: 2)
        store.installHostedPresentationTargets(target: mounted, pending: pending)
        await store.close(mounted)
        #expect(probe.retiredScopes.isEmpty)
    }

    @Test("close retires exact mounted and pending scopes")
    func closeRetiresExactMountedAndPendingScopes() async {
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let probe = NoticeScopeProbe(); store.delegate = probe
        let mounted = SessionPresentationIdentity(sessionID: "same", generation: 1)
        store.installHostedPresentationTargets(target: mounted, pending: mounted)
        await store.close(mounted)
        #expect(probe.retiredScopes == [.session(id: "same", generation: 1)])
    }

    @Test("clearProfile retires mounted and pending notice ownership")
    func clearProfileRetiresNoticeOwnership() {
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let probe = NoticeScopeProbe(); store.delegate = probe
        store.installHostedPresentationTargets(
            target: SessionPresentationIdentity(sessionID: "clear", generation: 3),
            pending: SessionPresentationIdentity(sessionID: "clear", generation: 4)
        )
        store.clearProfile()
        #expect(Set(probe.retiredScopes) == Set([
            .session(id: "clear", generation: 3), .session(id: "clear", generation: 4)
        ]))
    }

    @Test("remove retires mounted and pending notice ownership")
    func removeRetiresNoticeOwnership() {
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        let probe = NoticeScopeProbe(); store.delegate = probe
        store.installHostedPresentationTargets(
            target: SessionPresentationIdentity(sessionID: "remove", generation: 5),
            pending: SessionPresentationIdentity(sessionID: "remove", generation: 6)
        )
        store.remove(sessionID: "remove")
        #expect(Set(probe.retiredScopes) == Set([
            .session(id: "remove", generation: 5), .session(id: "remove", generation: 6)
        ]))
    }

    @Test("AppModel authoritative snapshot façade remains observable")
    func observationForwarding() throws {
        let model = AppModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.authoritativeSnapshot(for: "session")
        } onChange: {
            changed.withLock { $0 = true }
        }
        let snapshot = try SessionScenarioBuilder(seed: 81).openingTail(targetEncodedBytes: 4_096)
        model.installHostedAuthoritativeSnapshot(snapshot)
        #expect(changed.withLock { $0 })
        #expect(model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot)
    }

    @Test("Manage Session projection does not publish streaming-only snapshot churn")
    func contextProjectionIsNarrowlyObservable() throws {
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        var snapshot = try SessionScenarioBuilder(seed: 8_101).openingTail(targetEncodedBytes: 4_096)
        store.installHostedAuthoritativeSnapshot(snapshot)
        let baseline = try #require(store.contextPresentation(for: snapshot.sessionId))
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.contextPresentation(for: snapshot.sessionId)
        } onChange: {
            changed.withLock { $0 = true }
        }

        snapshot.streaming = snapshot.transcript.last
        store.replaceHostedSnapshot(snapshot)
        #expect(store.contextPresentation(for: snapshot.sessionId) == baseline)
        #expect(!changed.withLock { $0 })

        snapshot.cwd += "/nested"
        store.replaceHostedSnapshot(snapshot)
        #expect(changed.withLock { $0 })
        #expect(store.contextPresentation(for: snapshot.sessionId)?.cwd == snapshot.cwd)
    }

    @Test("mounted transcript window retains only an exact prefix while authority stays unchanged")
    func mountedTranscriptWindowUsesExactCoverage() throws {
        var tail = try SessionScenarioBuilder(seed: 8_811).openingTail(targetEncodedBytes: 4_096)
        tail.transcriptStart = 1
        tail.transcriptTotal = tail.transcript.count + 1
        let prefix = try #require(SessionScenarioBuilder(seed: 8_812).historyPage(count: 1, longRowBytes: 16).first)
        var visible = tail
        visible.transcript = [prefix] + tail.transcript
        visible.transcriptStart = max(0, (tail.transcriptStart ?? 1) - 1)
        visible.transcriptTotal = tail.transcriptTotal
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: tail, token: "token")
        store.installHostedLoadedHistory(visible: visible, authoritativeTail: tail)
        #expect(store.snapshot == tail)
        #expect(store.visibleTranscript.map(\.id) == visible.transcript.map(\.id))
        #expect(store.visibleTranscriptStart == visible.transcriptStart)
        #expect(store.visibleTranscriptEnd == tail.transcriptStart.map { $0 + tail.transcript.count })
        #expect(store.mountedTranscriptCoverage?.start == visible.transcriptStart)
        #expect(store.mountedTranscriptCoverage?.end == tail.transcriptStart.map { $0 + tail.transcript.count })
    }

    @Test("prefix reconciliation handles unchanged, sliding, and backward-expanded tails")
    func mountedTranscriptWindowReconcilesVisibleOrdinals() throws {
        let builder = SessionScenarioBuilder(seed: 8_816)
        let entries = builder.pagedMixedSession(totalEntries: 14).page(before: 10, count: 10)
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        var tail = try builder.openingTail(targetEncodedBytes: 4_096)
        tail.transcript = Array(entries[7..<10])
        tail.transcriptStart = 7
        tail.transcriptTotal = 11
        var visible = tail
        visible.transcript = Array(entries[2..<10])
        visible.transcriptStart = 2
        store.installHostedSubscription(snapshot: tail, token: "token")
        store.installHostedLoadedHistory(visible: visible, authoritativeTail: tail)

        // An unchanged tail keeps the exact loaded prefix.
        var unchanged = tail
        unchanged.eventSequence += 1
        store.replaceHostedSnapshot(unchanged)
        #expect(store.visibleTranscript.map(\.id) == entries[2..<10].map(\.id))
        #expect(store.mountedTranscriptCoverage?.end == 10)

        // A tail that slides forward promotes the old tail row at ordinal 7
        // into the prefix rather than dropping it or claiming a gap.
        var sliding = tail
        let eleven = builder.pagedMixedSession(totalEntries: 11).page(before: 11, count: 11)
        sliding.transcript = Array(eleven[8..<11])
        sliding.transcriptStart = 8
        sliding.transcriptTotal = 12
        sliding.leafEntryId = "grown-leaf"
        sliding.eventSequence += 2
        store.replaceHostedSnapshot(sliding)
        #expect(store.visibleTranscript.map(\.id) == eleven[2..<11].map(\.id))
        #expect(store.mountedTranscriptCoverage?.start == 2)
        #expect(store.mountedTranscriptCoverage?.end == 11)

        // Expanding backward trims the prefix to the rows before the new tail;
        // every overlap is still checked against the replacement authority.
        var expanding = tail
        expanding.transcript = Array(eleven[5..<10])
        expanding.transcriptStart = 5
        expanding.transcriptTotal = 12
        expanding.eventSequence += 3
        store.replaceHostedSnapshot(expanding)
        #expect(store.visibleTranscript.map(\.id) == entries[2..<10].map(\.id))
        #expect(store.mountedTranscriptCoverage?.start == 2)
        #expect(store.mountedTranscriptCoverage?.end == 10)
    }

    @Test("prefix reconciliation admits an exact contiguous append without overlap")
    func mountedTranscriptWindowAdmitsExactContiguousAppend() async throws {
        let builder = SessionScenarioBuilder(seed: 8_820)
        let entries = builder.pagedMixedSession(totalEntries: 12).page(before: 12, count: 12)

        func makeStore() throws -> (SessionPresentationStore, SessionSnapshot) {
            var tail = try builder.openingTail(targetEncodedBytes: 4_096)
            tail.transcript = Array(entries[7..<10])
            tail.transcriptStart = 7
            tail.transcriptTotal = 10
            var visible = tail
            visible.transcript = Array(entries[2..<10])
            visible.transcriptStart = 2
            let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
            store.installHostedSubscription(snapshot: tail, token: "token")
            store.installHostedLoadedHistory(visible: visible, authoritativeTail: tail)
            return (store, tail)
        }

        // The replacement starts exactly at the old visible end, so its rows
        // do not overlap the mounted sequence. A changed leaf and total are
        // admissible because session/runtime and structure revision remain
        // unchanged and the replacement is contiguous.
        do {
            let (store, tail) = try makeStore()
            var appended = tail
            appended.transcript = Array(entries[10..<12])
            appended.transcriptStart = 10
            appended.transcriptTotal = 12
            appended.leafEntryId = "appended-leaf"
            store.replaceHostedSnapshot(appended)
            #expect(Set(entries[2..<10].map(\.id)).isDisjoint(with: entries[10..<12].map(\.id)))
            #expect(store.visibleTranscript.map(\.id) == entries[2..<12].map(\.id))
            #expect(store.mountedTranscriptCoverage?.start == 2)
            #expect(store.mountedTranscriptCoverage?.end == 12)
            #expect(store.mountedTranscriptCoverage?.total == 12)
            #expect(store.mountedTranscriptCoverage?.leafEntryID == "appended-leaf")
        }

        // Ordinary structure notifications (including custom-entry appends)
        // preserve the browsing prefix while the next authoritative snapshot
        // proves its exact overlap.
        do {
            let (store, tail) = try makeStore()
            let sequence = tail.eventSequence + 1
            await store.admit(GatewayEvent(
                type: "event",
                topic: "session.structureChanged",
                sessionId: tail.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(tail.runtimeGeneration),
                    "eventSequence": .number(Double(sequence)),
                    "revision": .number(Double(tail.revision + 1)),
                    "data": .object(["branchChanged": .bool(false)]),
                ])
            ))
            #expect(store.mountedTranscriptCoverage?.start == 2)
            #expect(store.mountedTranscriptCoverage?.end == 10)

            var appended = tail
            appended.eventSequence = sequence + 1
            appended.transcript = Array(entries[10..<12])
            appended.transcriptStart = 10
            appended.transcriptTotal = 12
            appended.leafEntryId = "appended-leaf"
            store.replaceHostedSnapshot(appended)
            #expect(store.visibleTranscript.map(\.id) == entries[2..<12].map(\.id))
            #expect(store.mountedTranscriptCoverage?.start == 2)
            #expect(store.mountedTranscriptCoverage?.end == 12)
        }

        // A structure revision change invalidates the old mounted window;
        // the same adjacent append must not resurrect that prefix.
        do {
            let (store, tail) = try makeStore()
            let sequence = tail.eventSequence + 1
            await store.admit(GatewayEvent(
                type: "event",
                topic: "session.structureChanged",
                sessionId: tail.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(tail.runtimeGeneration),
                    "eventSequence": .number(Double(sequence)),
                    "revision": .number(Double(tail.revision + 1)),
                    "data": .object(["branchChanged": .bool(true)]),
                ])
            ))
            #expect(store.mountedTranscriptCoverage == nil)

            var appended = tail
            appended.eventSequence = sequence + 1
            appended.transcript = Array(entries[10..<12])
            appended.transcriptStart = 10
            appended.transcriptTotal = 12
            appended.leafEntryId = "appended-leaf"
            store.replaceHostedSnapshot(appended)
            #expect(store.visibleTranscript.map(\.id) == appended.transcript.map(\.id))
            #expect(store.mountedTranscriptCoverage == nil)
        }
    }

    @Test("prefix reconciliation rejects gaps and every identity conflict")
    func mountedTranscriptWindowRejectsGapsAndIdentityConflicts() throws {
        let builder = SessionScenarioBuilder(seed: 8_817)
        let entries = builder.pagedMixedSession(totalEntries: 14).page(before: 10, count: 10)

        func makeStore() throws -> (SessionPresentationStore, SessionSnapshot, [TranscriptItem]) {
            var tail = try builder.openingTail(targetEncodedBytes: 4_096)
            tail.transcript = Array(entries[7..<10])
            tail.transcriptStart = 7
            tail.transcriptTotal = 14
            var visible = tail
            visible.transcript = Array(entries[2..<10])
            visible.transcriptStart = 2
            let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
            store.installHostedSubscription(snapshot: tail, token: "token")
            store.installHostedLoadedHistory(visible: visible, authoritativeTail: tail)
            return (store, tail, entries)
        }

        // New authority begins after the visible end: no synthetic rows fill
        // the gap.
        do {
            let (store, tail, _) = try makeStore()
            var gap = tail
            gap.transcriptStart = 11
            gap.transcript = builder.pagedMixedSession(totalEntries: 14).page(before: 14, count: 3)
            gap.transcriptTotal = 14
            store.replaceHostedSnapshot(gap)
            #expect(store.mountedTranscriptCoverage == nil)
        }

        // A replacement beginning at the visible start needs no prefix.
        do {
            let (store, tail, _) = try makeStore()
            var replacement = tail
            replacement.transcriptStart = 2
            replacement.transcript = Array(entries[2..<10])
            replacement.transcriptTotal = 14
            store.replaceHostedSnapshot(replacement)
            #expect(store.mountedTranscriptCoverage == nil)
        }

        // A mismatched ID at one overlapping ordinal fails closed.
        do {
            let (store, tail, _) = try makeStore()
            var conflict = tail
            let replacement = SessionScenarioBuilder(seed: 99).pagedMixedSession(totalEntries: 11).page(before: 11, count: 3)
            conflict.transcript = replacement
            conflict.transcriptStart = 8
            conflict.transcriptTotal = 14
            store.replaceHostedSnapshot(conflict)
            #expect(store.mountedTranscriptCoverage == nil)
        }

        for mutation in ["runtime", "total"] {
            let (store, tail, _) = try makeStore()
            var conflict = tail
            switch mutation {
            case "runtime": conflict.runtimeGeneration += "-changed"
            default: conflict.transcriptTotal = 13
            }
            store.replaceHostedSnapshot(conflict)
            #expect(store.mountedTranscriptCoverage == nil)
        }

        // A leaf change alone is admissible when the projected tail overlaps
        // every visible ordinal exactly; the leaf is updated in coverage.
        do {
            let (store, tail, _) = try makeStore()
            var replacement = tail
            replacement.leafEntryId = "changed-leaf"
            store.replaceHostedSnapshot(replacement)
            #expect(store.visibleTranscript.map(\.id) == entries[2..<10].map(\.id))
            #expect(store.mountedTranscriptCoverage?.leafEntryID == "changed-leaf")
        }
    }

    @Test("nonprojectable leaf changes retain only exact projected overlap")
    func mountedTranscriptWindowAdmitsProjectedLeafChange() throws {
        var tail = try SessionScenarioBuilder(seed: 8_813).openingTail(targetEncodedBytes: 4_096)
        tail.transcriptStart = 1
        tail.transcriptTotal = tail.transcript.count + 1
        let prefix = try #require(SessionScenarioBuilder(seed: 8_814).historyPage(count: 1, longRowBytes: 16).first)
        var visible = tail
        visible.transcript = [prefix] + tail.transcript
        visible.transcriptStart = max(0, (tail.transcriptStart ?? 1) - 1)
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: tail, token: "token")
        store.installHostedLoadedHistory(visible: visible, authoritativeTail: tail)
        var replacement = tail
        replacement.eventSequence += 1
        replacement.leafEntryId = "different-leaf"
        store.replaceHostedSnapshot(replacement)
        #expect(store.snapshot == replacement)
        #expect(store.visibleTranscript.map(\.id) == visible.transcript.map(\.id))
        #expect(store.mountedTranscriptCoverage?.leafEntryID == "different-leaf")
    }

    @Test("branch change discards mounted prefix before an overlapping snapshot")
    func mountedTranscriptWindowRejectsBranchChangeBeforeSnapshot() async throws {
        var tail = try SessionScenarioBuilder(seed: 8_818).openingTail(targetEncodedBytes: 4_096)
        tail.transcriptStart = 1
        tail.transcriptTotal = tail.transcript.count + 1
        let prefix = try #require(SessionScenarioBuilder(seed: 8_819).historyPage(count: 1, longRowBytes: 16).first)
        var visible = tail
        visible.transcript = [prefix] + tail.transcript
        visible.transcriptStart = 0
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: tail, token: "token")
        store.installHostedLoadedHistory(visible: visible, authoritativeTail: tail)
        let sequence = tail.eventSequence + 1
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.structureChanged",
            sessionId: tail.sessionId,
            payload: .object([
                "runtimeGeneration": .string(tail.runtimeGeneration),
                "eventSequence": .number(Double(sequence)),
                "revision": .number(Double(tail.revision + 1)),
                "data": .object(["branchChanged": .bool(true)]),
            ])
        ))
        #expect(store.mountedTranscriptCoverage == nil)

        var replacement = tail
        replacement.eventSequence = sequence + 1
        store.replaceHostedSnapshot(replacement)
        #expect(store.visibleTranscript == replacement.transcript)
        #expect(store.mountedTranscriptCoverage == nil)
    }

    @Test("reconnect keeps only compatible prefix facts beside the newer authority")
    func reconnectInstallsAuthoritativeTailWithoutCopyingPrefix() throws {
        var current = try SessionScenarioBuilder(seed: 8_815).openingTail(targetEncodedBytes: 4_096)
        current.eventSequence = 4
        var incoming = current
        incoming.eventSequence = 5
        incoming.transcriptStart = current.transcriptStart
        #expect(SessionPresentationStore.installingSnapshot(
            current: current,
            authoritative: incoming,
            mode: .reconnect
        ) == incoming)

        incoming.eventSequence = 3
        #expect(SessionPresentationStore.installingSnapshot(
            current: current,
            authoritative: incoming,
            mode: .reconnect
        ) == current)

        current.liveActivityRevision = 4
        current.extensionActivityAsOf = "current"
        incoming = current
        incoming.eventSequence += 1
        incoming.liveActivityRevision = nil
        incoming.extensionActivityAsOf = "stale"
        let preserved = SessionPresentationStore.installingSnapshot(
            current: current,
            authoritative: incoming,
            mode: .reconnect
        )
        #expect(preserved.eventSequence == incoming.eventSequence)
        #expect(preserved.liveActivityRevision == 4)
        #expect(preserved.extensionActivityAsOf == "current")

        #expect(SessionPresentationStore.installingSnapshot(
            current: current,
            authoritative: incoming,
            mode: .freshPresentation
        ) == incoming)
    }

    @Test("page admission requires exact visible total and projected bounds")
    func pageAdmissionUsesExactFacts() {
        let request = ChatTranscriptPageRequest(
            sessionID: "session", presentationGeneration: 1,
            runtimeGeneration: "runtime", before: 20,
            expectedTotal: 28, expectedNextEntryID: "first"
        )
        #expect(request.canInstall(
            sessionID: "session", presentationGeneration: 1,
            runtimeGeneration: "runtime", transcriptStart: 20,
            transcriptTotal: 28, firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session", presentationGeneration: 1,
            runtimeGeneration: "runtime", transcriptStart: 20,
            transcriptTotal: nil, firstTranscriptID: "first"
        ))
        #expect(request.canInstallPage(
            start: 12, end: 20, total: 28, itemCount: 8, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 28, itemCount: 8, visibleItemCount: 7
        ))
    }

    @Test("admission preserves allowed LF and CR while rejecting other controls")
    func admissionBoundaryForMultilineValues() throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_810).openingTail(targetEncodedBytes: 4_096)
        snapshot.extensionPresentation.revision = 1
        snapshot.extensionPresentation.semanticState.editorText = "line one\r\nline two"
        snapshot.extensionPresentation.semanticState.statuses = ["multiline": "first\nsecond\rthird"]
        snapshot.extensionPresentation.semanticState.title = "title\r\ncontinued"
        snapshot.extensionPresentation.pendingInteractions = [
            ExtensionInteraction(
                id: "editor-boundary",
                hostEpoch: snapshot.extensionPresentation.hostEpoch,
                presentationRevision: 1,
                method: .editor,
                title: "Edit",
                message: "message\r\ncontinued",
                options: nil,
                placeholder: nil,
                prefill: "prefill\ncontinued\rfinal",
                expiresAt: nil
            )
        ]
        #expect(ExtensionPresentationPolicy.admit(snapshot.extensionPresentation))

        snapshot.extensionPresentation.semanticState.editorText = "rejected\u{1}control"
        #expect(!ExtensionPresentationPolicy.admit(snapshot.extensionPresentation))
    }

    @Test("session-open diagnostics identify the rejected projection")
    func sessionOpenDiagnosticPath() throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_813).openingTail(targetEncodedBytes: 4_096)
        snapshot.extensionPresentation.semanticState.statuses = [:]
        snapshot.extensionPresentation.semanticState.statusOwners = [
            "orphan": ExtensionOwner(id: "extension:subagents", title: "Subagents", source: "npm:pi-subagents")
        ]
        let snapshotValue = try JSONDecoder.gateway.decode(
            JSONValue.self,
            from: JSONEncoder.gateway.encode(snapshot)
        )
        let payload = try JSONEncoder.gateway.encode(JSONValue.object([
            "session": snapshotValue,
            "syncToken": .string("sync-token"),
            "subscriptionToken": .string("subscription-token"),
            "completionRevision": .number(0),
        ]))

        do {
            _ = try JSONDecoder.gateway.decode(GatewaySessionOpenResponse.self, from: payload)
            Issue.record("Malformed status ownership unexpectedly passed session-open admission")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.map(\.stringValue) == ["session", "extensionPresentation"])
        }
    }

    @Test("full input leases require bounded identities and valid timestamps")
    func inputLeaseAdmission() throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_812).openingTail(targetEncodedBytes: 4_096)
        snapshot.extensionPresentation.inputLease = .init(
            id: "", connectionId: "connection", surfaceId: "surface",
            surfaceRevision: 1, acquiredAt: "2026-01-01T00:00:00Z"
        )
        #expect(!ExtensionPresentationPolicy.admit(snapshot.extensionPresentation))
        snapshot.extensionPresentation.inputLease = .init(
            id: "lease", connectionId: "connection", surfaceId: "surface",
            surfaceRevision: 1, acquiredAt: "not-a-time"
        )
        #expect(!ExtensionPresentationPolicy.admit(snapshot.extensionPresentation))
    }

    @Test("multiline editor, paste, and interaction projections remain admitted")
    func multilineExtensionPresentationValues() throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_811).openingTail(targetEncodedBytes: 4_096)
        snapshot.extensionPresentation.revision = 1
        snapshot.extensionPresentation.semanticState.editorText = "first line\nsecond line"
        snapshot.extensionPresentation.pendingInteractions = [
            ExtensionInteraction(
                id: "editor",
                hostEpoch: snapshot.extensionPresentation.hostEpoch,
                presentationRevision: 1,
                method: .editor,
                title: "Edit",
                message: "line one\nline two",
                options: nil,
                placeholder: nil,
                prefill: "prefill one\nprefill two",
                expiresAt: nil
            )
        ]
        let model = AppModel()
        model.installHostedAuthoritativeSnapshot(snapshot)
        #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.extensionPresentation.semanticState.editorText == "first line\nsecond line")
        #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.extensionPresentation.pendingInteractions.first?.prefill == "prefill one\nprefill two")
    }

    @Test("cold cached snapshots never acquire live authority")
    func coldSnapshotIsNotAuthoritative() throws {
        let model = AppModel()
        let snapshot = try SessionScenarioBuilder(seed: 82).openingTail(targetEncodedBytes: 4_096)
        model.installHostedSnapshotWithoutPresentation(snapshot)
        #expect(model.authoritativeSnapshot(for: snapshot.sessionId) == nil)
        #expect(model.mountedPresentationTarget == nil)
    }

    @Test("disconnect retires lease authority while profile reset clears the projection")
    func disconnectAndProfileReset() throws {
        let snapshot = try SessionScenarioBuilder(seed: 83).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedAuthoritativeSnapshot(snapshot)
        let target = try #require(store.mountedTarget)
        let timelineBeforeRetirement = store.chatTimelineGeneration
        store.retireConnection()
        #expect(store.mountedTarget == target)
        #expect(store.chatTimelineGeneration > timelineBeforeRetirement)
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == snapshot)
        #expect(!store.hasInstalledSubscription(for: snapshot.sessionId))

        store.clearProfile()
        #expect(store.mountedTarget == nil)
        #expect(store.snapshot == nil)
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == nil)
    }

    @Test("canonical compaction delta replaces live state without reopening chat")
    func compactionDeltaAdvancesCanonicalChat() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_505).openingTail(targetEncodedBytes: 4_096)
        snapshot.phase = .compacting
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.leafEntryId = snapshot.transcript.last?.id
        snapshot.operation = SessionOperationState(
            id: nil,
            kind: .compaction,
            startedAt: "2026-08-24T20:49:00.000Z",
            reason: "threshold"
        )
        let parentID = snapshot.leafEntryId
        let item = TranscriptItem.summary(SummaryTranscriptItem(
            id: "compaction-live-1",
            parentId: parentID,
            timestamp: "2026-08-24T20:50:00.000Z",
            kind: .compaction,
            presentationId: nil,
            summary: "Preserved exact decisions",
            tokensBefore: 12_345,
            details: nil,
            usage: nil,
            fromHook: nil
        ))
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        let canonicalBefore = store.chatCanonicalGeneration
        let timelineBefore = store.chatTimelineGeneration
        let oldTotal = try #require(snapshot.transcriptTotal)

        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.compaction",
            sessionId: snapshot.sessionId,
            payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration),
                "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                "revision": .number(Double(snapshot.revision + 1)),
                "data": .object(["item": try JSONValue.encode(item)]),
            ])
        ))

        let installed = try #require(store.authoritativeSnapshot(for: snapshot.sessionId))
        #expect(installed.eventSequence == snapshot.eventSequence + 1)
        #expect(installed.transcriptTotal == oldTotal + 1)
        #expect(installed.transcript.last == item)
        #expect(installed.leafEntryId == item.id)
        #expect(installed.streaming == nil)
        #expect(store.chatCanonicalGeneration == canonicalBefore + 1)
        #expect(store.chatTimelineGeneration == timelineBefore + 1)
        #expect(ChatNotificationPresentation.runtime(in: installed).allSatisfy {
            $0.title != "Compacting context"
        })
        #expect(ChatNotificationPresentation.canonical(item, globalOrdinal: oldTotal)?.title == "Context compacted")
    }

    @Test("authoritative compaction snapshot invalidates mounted chat without reopening")
    func compactionSnapshotAdvancesMountedChat() async throws {
        var baseline = try SessionScenarioBuilder(seed: 8_506).openingTail(targetEncodedBytes: 4_096)
        baseline.phase = .compacting
        baseline.transcriptStart = 0
        baseline.transcriptTotal = baseline.transcript.count
        baseline.leafEntryId = baseline.transcript.last?.id
        baseline.operation = SessionOperationState(
            id: "manual-compaction",
            kind: .compaction,
            startedAt: "2026-08-24T20:49:00.000Z",
            reason: "manual"
        )
        let oldTotal = try #require(baseline.transcriptTotal)
        let item = TranscriptItem.summary(SummaryTranscriptItem(
            id: "compaction-snapshot-1",
            parentId: baseline.leafEntryId,
            timestamp: "2026-08-24T20:50:00.000Z",
            kind: .compaction,
            presentationId: "manual-compaction",
            summary: "Preserved exact decisions",
            tokensBefore: 12_345,
            details: nil,
            usage: nil,
            fromHook: nil
        ))
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: baseline, token: "token")
        let canonicalBefore = store.chatCanonicalGeneration
        let timelineBefore = store.chatTimelineGeneration
        var completed = baseline
        completed.eventSequence += 1
        completed.revision += 1
        completed.transcript.append(item)
        completed.transcriptTotal = oldTotal + 1
        completed.leafEntryId = item.id

        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.snapshot",
            sessionId: baseline.sessionId,
            payload: try JSONValue.encode(completed)
        ))

        let installed = try #require(store.authoritativeSnapshot(for: baseline.sessionId))
        #expect(installed.transcript.last == item)
        #expect(store.chatCanonicalGeneration == canonicalBefore + 1)
        #expect(store.chatTimelineGeneration == timelineBefore + 1)
        #expect(ChatNotificationPresentation.runtime(in: installed).allSatisfy {
            $0.title != "Compacting context"
        })
        #expect(ChatNotificationPresentation.canonical(item, globalOrdinal: oldTotal)?.title
            == "Context compacted")
    }

    @Test("overflow rebaseline installs only for the mounted subscription owner")
    func overflowRebaselineInstallsFreshAuthority() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 84).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        var recovery = snapshot
        recovery.eventSequence += 10
        recovery.revision += 10
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.rebaseline",
            sessionId: snapshot.sessionId,
            payload: .object([
                "reason": .string("subscription catch-up overflow"),
                "subscriptionToken": .string("token"),
                "snapshot": try JSONValue.encode(recovery),
            ])
        ))
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == recovery)

        var stale = recovery
        stale.eventSequence -= 1
        stale.revision -= 1
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.rebaseline",
            sessionId: snapshot.sessionId,
            payload: .object([
                "reason": .string("delayed recovery"),
                "subscriptionToken": .string("token"),
                "snapshot": try JSONValue.encode(stale),
            ])
        ))
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == recovery)

        var oldToken = recovery
        oldToken.eventSequence += 20
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.rebaseline",
            sessionId: snapshot.sessionId,
            payload: .object([
                "reason": .string("old token"),
                "subscriptionToken": .string("old-token"),
                "snapshot": try JSONValue.encode(oldToken),
            ])
        ))
        #expect(store.authoritativeSnapshot(for: snapshot.sessionId) == recovery)

        store.retireConnection()
        var ignored = recovery
        ignored.eventSequence += 10
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.rebaseline",
            sessionId: snapshot.sessionId,
            payload: .object([
                "reason": .string("subscription catch-up overflow"),
                "subscriptionToken": .string("token"),
                "snapshot": try JSONValue.encode(ignored),
            ])
        ))
        #expect(store.snapshot == recovery)
    }

    @Test("stale open response after connection retirement preserves the newer subscription")
    func staleOpenResponseCannotClearNewConnectionSubscription() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let staleSnapshot = try SessionScenarioBuilder(seed: 8_812).openingTail(targetEncodedBytes: 4_096)
            let newerSnapshot = try SessionScenarioBuilder(seed: 8_813).openingTail(targetEncodedBytes: 4_096)
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(staleSnapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[1])
            let requestID = try #require(request.objectValue?["id"]?.stringValue)

            store.retireConnection()
            store.installHostedSubscription(snapshot: newerSnapshot, token: "new-connection-token")
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(staleSnapshot),
                    "syncToken": .string("stale-sync"),
                    "subscriptionToken": .string("stale-token"),
                ]),
            ])))
            _ = try? await opening.value

            #expect(store.installedSubscriptionToken(for: newerSnapshot.sessionId) == "new-connection-token")
            #expect(store.authoritativeSnapshot(for: newerSnapshot.sessionId) == newerSnapshot)
            await client.close()
        }
    }

    @Test("queue projection changes only through sequenced Gateway authority")
    func confirmedQueueClear() throws {
        var snapshot = try SessionScenarioBuilder(seed: 84).openingTail(targetEncodedBytes: 4_096)
        snapshot.queueRevision = 7
        snapshot.queuedItems = [
            .init(id: "first", behavior: .steer, text: "duplicate", attachmentCount: 0),
            .init(id: "second", behavior: .steer, text: "duplicate", attachmentCount: 1),
            .init(id: "third", behavior: .followUp, text: "later", attachmentCount: 0),
        ]
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedAuthoritativeSnapshot(snapshot)
        let generation = store.chatTimelineGeneration

        // A command response is not a queue commit. Until the sequenced
        // Gateway snapshot/event arrives, every projection remains unchanged.
        #expect(store.chatTimelineGeneration == generation)
        #expect(store.snapshot?.queuedItems == snapshot.queuedItems)
        #expect(store.snapshot?.displayedQueuedMessages == snapshot.displayedQueuedMessages)
    }

    @Test("revocation rejects every sequenced event before cursor reduction")
    func revokedSequencedEvent() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 85).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        let target = try #require(store.mountedTarget)
        store.revokeIntake(target)
        await store.admit(GatewayEvent(
            type: "event",
            topic: "session.retry",
            sessionId: snapshot.sessionId,
            payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration),
                "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                "revision": .number(Double(snapshot.revision + 1)),
                "data": .object(["attempt": .number(2)]),
            ])
        ))
        #expect(store.snapshot?.eventSequence == snapshot.eventSequence)
        #expect(store.mountedTarget == nil)
    }

    @Test("only transcript-affecting extension semantics advance timeline generation")
    func runtimePresentationGeneration() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_501)
            .openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 10
        snapshot.revision = 20
        snapshot.extensionPresentation.hostEpoch = "presentation-host"
        snapshot.extensionPresentation.revision = 0
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        let baseline = store.chatTimelineGeneration

        func event(sequence: Int, semantic: JSONValue) -> GatewayEvent {
            GatewayEvent(
                type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "eventSequence": .number(Double(sequence)),
                    "revision": .number(Double(snapshot.revision)),
                    "data": .object([
                        "version": .number(3), "hostEpoch": .string("presentation-host"),
                        "revision": .number(Double(sequence - 10)), "semantic": semantic,
                    ]),
                ])
            )
        }

        await store.admit(event(
            sequence: 11, semantic: .object(["statuses": .object(["sync": .string("Synchronizing")])])
        ))
        #expect(store.snapshot?.extensionPresentation.semanticState.statuses["sync"] == "Synchronizing")
        // Status and working chrome are outside transcript projection and must
        // not issue row rebuilds or scroll work.
        #expect(store.chatTimelineGeneration == baseline)

        await store.admit(event(
            sequence: 12, semantic: .object(["statuses": .object(["sync": .string("Synchronizing")])])
        ))
        #expect(store.chatTimelineGeneration == baseline)

        await store.admit(event(
            sequence: 13, semantic: .object(["working": .object(["message": .string("Compacting context"), "visible": .bool(true)])])
        ))
        #expect(store.chatTimelineGeneration == baseline)

        await store.admit(event(
            sequence: 14, semantic: .object(["hiddenThinkingLabel": .string("Reasoning")])
        ))
        #expect(store.snapshot?.extensionPresentation.semanticState.hiddenThinkingLabel == "Reasoning")
        #expect(store.chatTimelineGeneration == baseline + 1)

        await store.admit(event(
            sequence: 15, semantic: .object(["hiddenThinkingLabel": .string("Reasoning")])
        ))
        #expect(store.chatTimelineGeneration == baseline + 1)

        await store.admit(event(
            sequence: 16, semantic: .object(["hiddenThinkingLabel": .null])
        ))
        #expect(store.snapshot?.extensionPresentation.semanticState.hiddenThinkingLabel == nil)
        #expect(store.chatTimelineGeneration == baseline + 2)
    }

    @Test("extension presentation rejects stale host epochs and revisions")
    func extensionPresentationScopeAdmission() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_502).openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 20
        snapshot.extensionPresentation.hostEpoch = "current-host"
        snapshot.extensionPresentation.revision = 4
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: snapshot, token: "token")

        func status(sequence: Int, host: String, presentationRevision: Int, text: String) -> GatewayEvent {
            GatewayEvent(type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId, payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration),
                "eventSequence": .number(Double(sequence)),
                "revision": .number(Double(snapshot.revision)),
                "data": .object([
                    "version": .number(3), "hostEpoch": .string(host),
                    "revision": .number(Double(presentationRevision)),
                    "semantic": .object(["statuses": .object(["scope": .string(text)])]),
                ]),
            ]))
        }

        // Duplicate presentation revisions are inert while still consuming the
        // authoritative session event cursor.
        await store.admit(status(sequence: 21, host: "current-host", presentationRevision: 4, text: "duplicate"))
        #expect(store.snapshot?.extensionPresentation.semanticState.statuses["scope"] == nil)
        await store.admit(status(sequence: 22, host: "current-host", presentationRevision: 5, text: "current"))
        #expect(store.snapshot?.extensionPresentation.semanticState.statuses["scope"] == "current")
        #expect(store.snapshot?.extensionPresentation.revision == 5)
        await store.admit(status(sequence: 23, host: "current-host", presentationRevision: 3, text: "reordered"))
        #expect(store.snapshot?.eventSequence == 22)
        #expect(store.snapshot?.extensionPresentation.revision == 5)
    }

    @Test("surface mutations use full upserts, explicit removals, and exact aggregate revisions")
    func extensionSurfaceMutationAdmission() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_503).openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 30
        snapshot.extensionPresentation.hostEpoch = "surface-host"
        snapshot.extensionPresentation.revision = 0
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: snapshot, token: "token")

        func event(sequence: Int, revision: Int, fields: [String: JSONValue]) -> GatewayEvent {
            var data = fields
            data["version"] = .number(3)
            data["hostEpoch"] = .string("surface-host")
            data["revision"] = .number(Double(revision))
            return GatewayEvent(type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId, payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration),
                "eventSequence": .number(Double(sequence)), "revision": .number(Double(snapshot.revision)),
                "data": .object(data),
            ]))
        }
        let surface: JSONValue = .object([
            "id": .string("surface"), "kind": .string("future-kind"), "placement": .string("transcript"),
            "lifecycle": .string("restored"), "revision": .number(1), "focused": .bool(false), "inputMode": .string("none"),
            "frame": .object([
                "width": .number(20), "height": .number(1), "plainText": .string("Readable fallback"),
                "lines": .array([.object([
                    "plainText": .string("Readable fallback"),
                    "runs": .array([.object(["text": .string("Readable fallback"), "style": .object([:])])]),
                ])]),
            ]),
        ])
        await store.admit(event(sequence: 31, revision: 1, fields: ["surfaceUpserts": .array([surface])]))
        #expect(store.snapshot?.extensionPresentation.surfaces.first?.kind == .unknown)
        #expect(store.snapshot?.extensionPresentation.surfaces.first?.frame.plainText == "Readable fallback")

        await store.admit(event(sequence: 32, revision: 1, fields: ["surfaceRemovals": .array([.string("surface")])]))
        #expect(store.snapshot?.extensionPresentation.surfaces.count == 1)
        #expect(store.snapshot?.extensionPresentation.revision == 1)

        await store.admit(event(sequence: 33, revision: 2, fields: ["surfaceRemovals": .array([.string("surface")])]))
        #expect(store.snapshot?.extensionPresentation.surfaces.isEmpty == true)
        #expect(store.snapshot?.extensionPresentation.revision == 2)

        await store.admit(event(sequence: 34, revision: 4, fields: ["capabilities": .array([.string("gap")])]))
        #expect(store.snapshot?.extensionPresentation.revision == 2)
    }

    @Test("exact-next malformed recognized events do not advance authority")
    func exactNextMalformedEventResynchronizes() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_507).openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 34
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        await store.admit(GatewayEvent(
            type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId,
            payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration), "eventSequence": .number(35),
                "revision": .number(Double(snapshot.revision)), "data": .object(["version": .string("malformed")]),
            ])
        ))
        #expect(store.snapshot?.eventSequence == 34)
        #expect(store.snapshot?.extensionPresentation.revision == snapshot.extensionPresentation.revision)
    }

    @Test("malformed exact-next editor directives are atomic and do not advance")
    func malformedEditorDirectiveResynchronizes() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_506).openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 35
        snapshot.extensionPresentation.hostEpoch = "editor-host"
        snapshot.extensionPresentation.revision = 2
        snapshot.extensionPresentation.semanticState.editorRevision = 3
        snapshot.extensionPresentation.semanticState.editorText = "A"
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        await store.admit(GatewayEvent(
            type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId,
            payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration), "eventSequence": .number(36), "revision": .number(Double(snapshot.revision)),
                "data": .object([
                    "version": .number(3), "hostEpoch": .string("editor-host"), "revision": .number(3),
                    "semantic": .object([
                        "editorAction": .string("paste"), "editorDelta": .string("B"),
                        "editorText": .string("AX"), "editorRevision": .number(4),
                    ]),
                ]),
            ])
        ))
        #expect(store.snapshot?.eventSequence == 35)
        #expect(store.snapshot?.extensionPresentation.revision == 2)
        #expect(store.snapshot?.extensionPresentation.semanticState.editorText == "A")
    }

    @Test("incomplete surface baselines converge through exact-next full frames")
    func incompleteSurfaceProjectionConverges() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 8_505).openingTail(targetEncodedBytes: 4_096)
        snapshot.eventSequence = 40
        snapshot.extensionPresentation.hostEpoch = "fitted-host"
        snapshot.extensionPresentation.revision = 10
        snapshot.extensionPresentation.projection = .init(
            complete: false, omitted: ["surfaces"],
            omittedSurfaces: [.init(id: "omitted", revision: 5)]
        )
        snapshot.extensionPresentation.inputLease = .init(
            id: "lease", connectionId: "connection", surfaceId: "omitted",
            surfaceRevision: 5, acquiredAt: "1970-01-01T00:00:00.000Z"
        )
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: snapshot, token: "token")
        let surface: JSONValue = .object([
            "id": .string("omitted"), "kind": .string("overlay"), "placement": .string("overlay"),
            "lifecycle": .string("blocking"), "revision": .number(6), "focused": .bool(true), "inputMode": .string("keys"),
            "frame": .object([
                "width": .number(20), "height": .number(1), "plainText": .string("Ready"),
                "lines": .array([.object(["plainText": .string("Ready"), "runs": .array([.object(["text": .string("Ready"), "style": .object([:])])])])]),
            ]),
        ])
        let lease: JSONValue = .object([
            "id": .string("lease"), "connectionId": .string("connection"), "surfaceId": .string("omitted"),
            "surfaceRevision": .number(6), "acquiredAt": .string("1970-01-01T00:00:00.000Z"),
        ])
        await store.admit(GatewayEvent(
            type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId,
            payload: .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration), "eventSequence": .number(41), "revision": .number(Double(snapshot.revision)),
                "data": .object(["version": .number(3), "hostEpoch": .string("fitted-host"), "revision": .number(11),
                    "surfaceUpserts": .array([surface]), "inputLease": lease]),
            ])
        ))
        #expect(store.snapshot?.extensionPresentation.surfaces.first?.revision == 6)
        #expect(store.snapshot?.extensionPresentation.inputLease?.surfaceRevision == 6)
        #expect(store.snapshot?.extensionPresentation.projection == nil)
        #expect(store.snapshot?.eventSequence == 41)
    }

    @Test("authoritative snapshots replace the complete presentation epoch")
    func extensionPresentationEpochReplacement() throws {
        var first = try SessionScenarioBuilder(seed: 8_504).openingTail(targetEncodedBytes: 4_096)
        first.extensionPresentation.hostEpoch = "old-host"
        first.extensionPresentation.revision = 7
        first.extensionPresentation.semanticState.statuses = ["old": "stale"]
        let store = SessionPresentationStore(client: GatewayClient(), performanceSignposts: SystemPerformanceSignposts.shared)
        store.installHostedSubscription(snapshot: first, token: "token")
        var replacement = first
        replacement.eventSequence += 1
        replacement.revision += 1
        replacement.extensionPresentation.hostEpoch = "new-host"
        replacement.extensionPresentation.revision = 0
        replacement.extensionPresentation.semanticState.statuses = [:]
        store.installHostedSubscription(snapshot: replacement, token: "replacement")
        #expect(store.snapshot?.extensionPresentation.hostEpoch == "new-host")
        #expect(store.snapshot?.extensionPresentation.semanticState.statuses.isEmpty == true)
    }

    @Test("runtime replacement clears secondary projections and advances their reload owners")
    func runtimeReplacementClearsSecondaryProjection() throws {
        var current = try SessionScenarioBuilder(seed: 8_504).openingTail(targetEncodedBytes: 4_096)
        current.runtimeGeneration = "runtime-a"
        var replacement = current
        replacement.runtimeGeneration = "runtime-b"
        replacement.revision += 1

        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: current, token: "token")
        store.installHostedSecondaryProjection(
            context: .object(["runtime": .string("a")]),
            tree: [SessionTreeNode(
                id: "entry",
                parentId: nil,
                timestamp: "2026-08-17T00:00:00.000Z",
                kind: "message",
                label: nil,
                preview: "Entry",
                role: .user,
                depth: 0,
                childCount: 0,
                isCurrentPath: true
            )],
            commands: [.init(name: "command", description: nil, argumentHint: nil, source: .extension, sourcePath: "/extension")],
            resources: .object(["runtime": .string("a")])
        )
        let structureRevision = store.structureRevision(for: current.sessionId)
        let contextRevision = store.contextRevision(for: current.sessionId)
        let resourceRevision = store.resourceRevision(for: current.sessionId)

        #expect(store.prepareSecondaryProjectionForRuntimeInstallation(replacement))
        #expect(store.context == nil)
        #expect(store.sessionTree.isEmpty)
        #expect(store.commands.isEmpty)
        #expect(store.resources == nil)
        #expect(store.structureRevision(for: current.sessionId) == structureRevision + 1)
        #expect(store.contextRevision(for: current.sessionId) == contextRevision + 1)
        #expect(store.resourceRevision(for: current.sessionId) == resourceRevision + 1)
        #expect(!store.prepareSecondaryProjectionForRuntimeInstallation(current))
    }

    @Test("a secondary response cannot publish after exact token replacement")
    func staleSecondaryResponse() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let snapshot = try SessionScenarioBuilder(seed: 84).openingTail(targetEncodedBytes: 4_096)
            let store = await MainActor.run {
                let store = SessionPresentationStore(
                    client: client,
                    performanceSignposts: SystemPerformanceSignposts.shared
                )
                store.installHostedSubscription(snapshot: snapshot, token: "first")
                return store
            }
            let loading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let frame = await socket.sentFrames()[1]
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            let requestID = try #require(request.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object(["stale": .bool(true)]),
            ])))
            await loading.value
            #expect(await MainActor.run { store.context } == nil)

            let errorProbe = SecondaryErrorProbe()
            await MainActor.run {
                store.delegate = errorProbe
                store.installHostedSubscription(snapshot: snapshot, token: "error-old")
            }
            let rejectedLoading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 3)
            let rejectedFrame = await socket.sentFrames()[2]
            let rejectedRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: rejectedFrame)
            let rejectedRequestID = try #require(rejectedRequest.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("error-replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(rejectedRequestID),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("busy"),
                    "message": .string("obsolete failure"),
                    "retryable": .bool(true),
                ]),
            ])))
            await rejectedLoading.value
            #expect(await MainActor.run { errorProbe.errors.isEmpty })

            await MainActor.run {
                store.installHostedSubscription(snapshot: snapshot, token: "revoked")
            }
            let revokedLoading = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 4)
            let revokedFrame = await socket.sentFrames()[3]
            let revokedRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: revokedFrame)
            let revokedRequestID = try #require(revokedRequest.objectValue?["id"]?.stringValue)
            await MainActor.run {
                if let target = store.mountedTarget { store.revokeIntake(target) }
            }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(revokedRequestID),
                "ok": .bool(true),
                "result": .object(["revoked": .bool(true)]),
            ])))
            await revokedLoading.value
            #expect(await MainActor.run { store.context } == nil)

            await MainActor.run {
                store.installHostedSubscription(snapshot: snapshot, token: "command-old")
            }
            let rejectedCommands = Task { await store.loadCommands(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 5)
            let commandFrame = await socket.sentFrames()[4]
            let commandRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: commandFrame)
            let commandRequestID = try #require(commandRequest.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("command-replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(commandRequestID),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("busy"),
                    "message": .string("obsolete command failure"),
                    "retryable": .bool(true),
                ]),
            ])))
            await rejectedCommands.value
            #expect(await MainActor.run { errorProbe.errors.isEmpty })
            await client.close()
        }
    }

    @Test("command catalog readiness belongs to the exact mounted subscription")
    func commandCatalogReadiness() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","skill-prompt.v1"]}"#.utf8))
            _ = try await connecting.value

            let snapshot = try SessionScenarioBuilder(seed: 842).openingTail(targetEncodedBytes: 4_096)
            let store = await MainActor.run {
                let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
                store.installHostedSubscription(snapshot: snapshot, token: "catalog")
                return store
            }
            let loading = Task { await store.loadCommands(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[1])
            let requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
                "result": .object(["commands": .array([.object([
                    "name": .string("skill:review"), "description": .string("Review"),
                    "argumentHint": .null, "source": .string("skill"), "sourcePath": .string("/skill/review"),
                ])])]),
            ])))
            await loading.value
            let mounted = await MainActor.run { store.mountedTarget }
            #expect(await MainActor.run { store.commandCatalogTarget } == mounted)
            #expect(await MainActor.run { store.commands.map(\.name) } == ["skill:review"])

            await MainActor.run { store.retireConnection() }
            #expect(await MainActor.run { store.commandCatalogTarget } == nil)
            await MainActor.run { store.installHostedSubscription(snapshot: snapshot, token: "catalog-reconnect") }

            let replacement = Task { await store.loadCommands(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 3)
            #expect(await MainActor.run { store.commandCatalogTarget } == nil)
            let replacementRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[2])
            let replacementID = try #require(replacementRequest.objectValue?["id"]?.stringValue)
            await MainActor.run { store.replaceHostedSubscriptionToken("replacement") }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(replacementID), "ok": .bool(true),
                "result": .object(["commands": .array([])]),
            ])))
            await replacement.value
            #expect(await MainActor.run { store.commandCatalogTarget } == nil)
            #expect(await MainActor.run { store.commands.map(\.name) } == ["skill:review"])
            await client.close()
        }
    }

    @Test("newer same-subscription context load rejects an older completion")
    func newestSecondaryLoadWins() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let snapshot = try SessionScenarioBuilder(seed: 841).openingTail(targetEncodedBytes: 4_096)
            let store = await MainActor.run {
                let store = SessionPresentationStore(
                    client: client,
                    performanceSignposts: SystemPerformanceSignposts.shared
                )
                store.installHostedSubscription(snapshot: snapshot, token: "subscription")
                return store
            }

            let older = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let olderFrame = await socket.sentFrames()[1]
            let olderRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: olderFrame)
            let olderID = try #require(olderRequest.objectValue?["id"]?.stringValue)

            let newer = Task { await store.loadContext(sessionID: snapshot.sessionId) }
            try await socket.waitUntilSent(count: 3)
            let newerFrame = await socket.sentFrames()[2]
            let newerRequest = try JSONDecoder.gateway.decode(JSONValue.self, from: newerFrame)
            let newerID = try #require(newerRequest.objectValue?["id"]?.stringValue)

            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(newerID),
                "ok": .bool(true),
                "result": .object(["generation": .string("newer")]),
            ])))
            await newer.value
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(olderID),
                "ok": .bool(true),
                "result": .object(["generation": .string("older")]),
            ])))
            await older.value

            #expect(await MainActor.run { store.context } == .object(["generation": .string("newer")]))
            await client.close()
        }
    }

    @Test("closing an old mount cannot clear a newer suspended open intent")
    func oldClosePreservesNewOpen() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let oldSnapshot = try SessionScenarioBuilder(seed: 87).openingTail(targetEncodedBytes: 4_096)
            var newSnapshot = try SessionScenarioBuilder(seed: 88).openingTail(targetEncodedBytes: 4_096)
            newSnapshot.sessionId = "replacement-session"
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )
            store.installHostedSubscription(snapshot: oldSnapshot, token: "old-token")
            let oldTarget = try #require(store.mountedTarget)
            let opening = Task { try await store.open(newSnapshot.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object(["closed": .bool(true)]),
            ])))

            try await socket.waitUntilSent(count: 3)
            store.revokeIntake(oldTarget)
            await store.close(oldTarget)
            // The close belongs to the superseded owner and must not release
            // its revocation while the replacement remains pending.
            #expect(!store.owns(oldTarget))
            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(newSnapshot),
                    "syncToken": .string("new-sync"),
                    "subscriptionToken": .string("new-token"),
                    "completionRevision": .number(5),
                ]),
            ])))

            try await socket.waitUntilSent(count: 4)
            frame = await socket.sentFrames()[3]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            id = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: 4, expectedRevision: 5)
            _ = try await opening.value
            #expect(store.mountedTarget?.sessionID == newSnapshot.sessionId)
            #expect(store.authoritativeSnapshot(for: newSnapshot.sessionId) == newSnapshot)
            await client.close()
        }
    }

    @Test("active fresh open publishes an empty positive-start tail before optional history")
    func freshOpenPublishesEmptyActiveTailImmediately() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var baseline = try SessionScenarioBuilder(seed: 8_905).openingTail(targetEncodedBytes: 4_096)
            baseline.phase = .compacting
            baseline.transcript = []
            baseline.transcriptStart = 10
            baseline.transcriptTotal = 10
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )
            let opening = Task { try await store.open(baseline.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline),
                    "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"),
                    "completionRevision": .number(6),
                ]),
            ])))

            try await socket.waitUntilSent(count: 3)
            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            requestID = try #require(request.objectValue?["id"]?.stringValue)
            #expect(request.objectValue?["method"]?.stringValue == "session.sync")
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: 3, expectedRevision: 6)

            _ = try await opening.value
            #expect(store.snapshot?.phase == .compacting)
            #expect(store.snapshot?.transcriptStart == 10)
            #expect(store.snapshot?.transcript.isEmpty == true)
            #expect(await socket.sentFrames().count >= 4)
            await client.close()
        }
    }

    @Test("a terminal suffix racing fresh mount installs atomically while attention keeps the open revision")
    func terminalSuffixRacingFreshMount() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var baseline = try SessionScenarioBuilder(seed: 8_906).openingTail(targetEncodedBytes: 4_096)
            baseline.phase = .running
            baseline.eventSequence = 20
            var terminal = baseline
            terminal.phase = .idle
            terminal.eventSequence = 21
            terminal.revision += 1
            terminal.operation = nil
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(baseline.sessionId) }
            try await socket.waitUntilSent(count: 2)
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[1])
            let openID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline), "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"), "completionRevision": .number(7),
                ]),
            ])))
            try await socket.waitUntilSent(count: 3)
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[2])
            let syncID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(syncID), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            await store.admit(GatewayEvent(
                type: "event",
                topic: "session.snapshot",
                sessionId: baseline.sessionId,
                payload: try JSONValue.encode(terminal)
            ))
            let attention = try await nextAttentionRead(socket, startingAt: 3)
            #expect(attention.request.objectValue?["params"]?.objectValue?["throughCompletionRevision"] == .number(7))
            #expect(store.mountedTarget?.sessionID == baseline.sessionId)
            #expect(store.snapshot?.eventSequence == 21)
            #expect(store.snapshot?.phase == .idle)
            let attentionID = try #require(attention.request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(attentionID), "ok": .bool(true),
                "result": .object(["isUnread": .bool(false)]),
            ])))
            _ = try await opening.value
            await client.close()
        }
    }

    @Test("active fresh open publishes a sparse fitted tail without mandatory history catch-up")
    func freshOpenPublishesSparseActiveTailImmediately() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var baseline = try SessionScenarioBuilder(seed: 8_907).openingTail(targetEncodedBytes: 4_096)
            baseline.phase = .running
            baseline.transcript = SessionScenarioBuilder(seed: 8_908).historyPage(count: 20, longRowBytes: 16)
            baseline.transcriptStart = 10
            baseline.transcriptTotal = 30
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )
            let opening = Task { try await store.open(baseline.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline),
                    "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"),
                    "completionRevision": .number(6),
                ]),
            ])))

            try await socket.waitUntilSent(count: 3)
            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            requestID = try #require(request.objectValue?["id"]?.stringValue)
            #expect(request.objectValue?["method"]?.stringValue == "session.sync")
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(requestID), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: 3, expectedRevision: 6)

            _ = try await opening.value
            #expect(store.snapshot?.phase == .running)
            #expect(store.snapshot?.transcript.map(\.id) == baseline.transcript.map(\.id))
            let methods = try await socket.sentFrames().dropFirst().compactMap { frame -> String? in
                let value = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
                return value.objectValue?["method"]?.stringValue
            }
            #expect(!methods.contains("session.transcript"))
            await client.close()
        }
    }

    @Test("active presentation lease renews canonical attention for mounted completions")
    func activePresentationLeaseReadsMountedCompletions() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let baseline = try SessionScenarioBuilder(seed: 8_929).openingTail(targetEncodedBytes: 4_096)
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(baseline.sessionId) }
            try await socket.waitUntilSent(count: 2)
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[1])
            let openID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline), "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"), "completionRevision": .number(2),
                ]),
            ])))
            try await socket.waitUntilSent(count: 3)
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[2])
            let syncID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(syncID), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            let initialAttentionIndex = try await answerAttentionRead(socket, frameIndex: 3, expectedRevision: 2)
            _ = try await opening.value

            let target = try #require(store.mountedTarget)
            store.setPresentationVisible(target, visible: true)
            var visibility = try await nextRequest(
                "session.presentation.set",
                socket: socket,
                startingAt: initialAttentionIndex + 1
            )
            request = visibility.request
            #expect(request.objectValue?["method"]?.stringValue == "session.presentation.set")
            #expect(request.objectValue?["params"]?.objectValue?["subscriptionToken"] == .string("subscription"))
            #expect(request.objectValue?["params"]?.objectValue?["revision"] == .number(1))
            #expect(request.objectValue?["params"]?.objectValue?["visible"] == .bool(true))
            let visibleID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(visibleID), "ok": .bool(true),
                "result": .object(["visible": .bool(true), "revision": .number(1)]),
            ])))

            store.observeAttentionSummary(SessionSummaryUpdate(
                sessionId: baseline.sessionId,
                summaryRevision: 9,
                phase: .idle,
                name: nil,
                updatedAt: "2026-01-01T00:00:00Z",
                messageCount: 2,
                firstMessage: "prompt",
                completionRevision: 3,
                attentionRevision: 4,
                isUnread: true
            ))
            let mountedAttentionIndex = try await answerAttentionRead(
                socket,
                frameIndex: visibility.index + 1,
                expectedRevision: 3
            )

            store.setPresentationVisible(target, visible: false)
            visibility = try await nextRequest(
                "session.presentation.set",
                socket: socket,
                startingAt: mountedAttentionIndex + 1
            )
            request = visibility.request
            #expect(request.objectValue?["method"]?.stringValue == "session.presentation.set")
            #expect(request.objectValue?["params"]?.objectValue?["revision"] == .number(2))
            #expect(request.objectValue?["params"]?.objectValue?["visible"] == .bool(false))
            let hiddenID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(hiddenID), "ok": .bool(true),
                "result": .object(["visible": .bool(false), "revision": .number(2)]),
            ])))
            await client.close()
        }
    }

    @Test("attention acknowledgement retries the exact installed completion revision")
    func attentionReadRetriesExactRevision() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let baseline = try SessionScenarioBuilder(seed: 8_930).openingTail(targetEncodedBytes: 4_096)
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(baseline.sessionId) }
            try await socket.waitUntilSent(count: 2)
            let open = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[1])
            let openID = try #require(open.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline), "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"), "completionRevision": .number(17),
                ]),
            ])))
            try await socket.waitUntilSent(count: 3)
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[2])
            let syncID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(syncID), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            let firstAttention = try await nextAttentionRead(socket, startingAt: 3)
            request = firstAttention.request
            #expect(request.objectValue?["method"]?.stringValue == "session.attention.read")
            #expect(store.snapshot?.sessionId == baseline.sessionId)
            #expect(request.objectValue?["params"]?.objectValue?["throughCompletionRevision"] == .number(17))
            let firstAttentionID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(firstAttentionID), "ok": .bool(false),
                "error": .object(["code": .string("busy"), "message": .string("retry"), "retryable": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: firstAttention.index + 1, expectedRevision: 17)
            _ = try await opening.value
            await client.close()
        }
    }

    @Test("transient malformed session-open response retries before surfacing failure")
    func transientMalformedOpenRetries() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var baseline = try SessionScenarioBuilder(seed: 8_907).openingTail(targetEncodedBytes: 4_096)
            baseline.extensionPresentation.hostEpoch = "retry-host"
            baseline.extensionPresentation.revision = 0
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(baseline.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frames = await socket.sentFrames()
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[1])
            let malformedID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(malformedID), "ok": .bool(true),
                "result": .object(["syncToken": .string("missing-session"), "subscriptionToken": .string("unused")]),
            ])))

            try await socket.waitUntilSent(count: 3)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[2])
            #expect(request.objectValue?["method"]?.stringValue == "session.close")
            #expect(request.objectValue?["params"]?.objectValue?["subscriptionToken"] == .string("unused"))
            let firstCloseID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(firstCloseID), "ok": .bool(true),
                "result": .object(["closed": .bool(true)]),
            ])))

            try await socket.waitUntilSent(count: 4)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[3])
            #expect(request.objectValue?["method"]?.stringValue == "session.open")
            let secondMalformedID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(secondMalformedID), "ok": .bool(true),
                "result": .object(["syncToken": .string("still-missing-session"), "subscriptionToken": .string("unused-again")]),
            ])))

            try await socket.waitUntilSent(count: 5)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[4])
            #expect(request.objectValue?["method"]?.stringValue == "session.close")
            #expect(request.objectValue?["params"]?.objectValue?["subscriptionToken"] == .string("unused-again"))
            let secondCloseID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(secondCloseID), "ok": .bool(true),
                "result": .object(["closed": .bool(true)]),
            ])))

            try await socket.waitUntilSent(count: 6)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[5])
            #expect(request.objectValue?["method"]?.stringValue == "session.open")
            let retryID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(retryID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(baseline),
                    "syncToken": .string("retry-sync"),
                    "subscriptionToken": .string("retry-subscription"),
                    "completionRevision": .number(9),
                ]),
            ])))

            try await socket.waitUntilSent(count: 7)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[6])
            #expect(request.objectValue?["method"]?.stringValue == "session.sync")
            let syncID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(syncID), "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: 7, expectedRevision: 9)

            _ = try await opening.value
            #expect(store.snapshot?.sessionId == baseline.sessionId)
            await client.close()
        }
    }

    @Test("malformed open tokens close only the bounded provisional subscription")
    func malformedOpenTokensPreserveProvisionalCleanup() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let baseline = try SessionScenarioBuilder(seed: 8_909).openingTail(targetEncodedBytes: 4_096)
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(baseline.sessionId) }
            let malformedTokens = ["", String(repeating: "x", count: 201), "control\u{1}token"]
            for (attempt, malformedToken) in malformedTokens.enumerated() {
                let openFrame = 2 + attempt * 2
                try await socket.waitUntilSent(count: openFrame)
                var request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[openFrame - 1])
                let openID = try #require(request.objectValue?["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                    "result": .object([
                        "session": try JSONValue.encode(baseline),
                        "syncToken": .string(malformedToken),
                        "subscriptionToken": .string("provisional-\(attempt)"),
                    ]),
                ])))
                try await socket.waitUntilSent(count: openFrame + 1)
                request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[openFrame])
                #expect(request.objectValue?["method"]?.stringValue == "session.close")
                #expect(request.objectValue?["params"]?.objectValue?["subscriptionToken"] == .string("provisional-\(attempt)"))
                let closeID = try #require(request.objectValue?["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(closeID), "ok": .bool(true),
                    "result": .object(["closed": .bool(true)]),
                ])))
            }
            await #expect(throws: GatewayFailure.self) { try await opening.value }
            #expect(!store.hasInstalledSubscription(for: baseline.sessionId))
            #expect(store.mountedTarget == nil)
            await client.close()
        }
    }

    @Test("terminal malformed session-open response propagates actionable failure after two retries")
    func terminalMalformedOpenPropagates() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let model = AppModel(
                client: client,
                cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
            )
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            let connecting = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            let opening = Task { try await model.openSessionPresentation("terminal-malformed") }
            for attempt in 0..<3 {
                let openFrameCount = 2 + attempt * 2
                try await socket.waitUntilSent(count: openFrameCount)
                var frames = await socket.sentFrames()
                var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[openFrameCount - 1])
                #expect(request.objectValue?["method"]?.stringValue == "session.open")
                let openID = try #require(request.objectValue?["id"]?.stringValue)
                let token = "malformed-token-\(attempt)"
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                    "result": .object([
                        "syncToken": .string("malformed-sync-\(attempt)"),
                        "subscriptionToken": .string(token),
                    ]),
                ])))

                try await socket.waitUntilSent(count: openFrameCount + 1)
                frames = await socket.sentFrames()
                request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[openFrameCount])
                #expect(request.objectValue?["method"]?.stringValue == "session.close")
                #expect(request.objectValue?["params"]?.objectValue?["subscriptionToken"] == .string(token))
                let closeID = try #require(request.objectValue?["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(closeID), "ok": .bool(true),
                    "result": .object(["closed": .bool(true)]),
                ])))
            }

            do {
                _ = try await opening.value
                Issue.record("terminal malformed open unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "invalid_response")
                #expect(failure.message.contains("session.open"))
                #expect(failure.message.contains("session"))
            }
            #expect((await socket.sentFrames()).count == 7)
            #expect(model.visibleNotices.last?.title.contains("session.open") == true)
            #expect(model.visibleNotices.last?.actions.contains(where: { $0.id == "view-logs" }) == true)
            await client.close()
        }
    }

    @Test("semantic replay rejection retries before provisional publication")
    func rejectedReplayRetriesSynchronization() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var baseline = try SessionScenarioBuilder(seed: 8_908).openingTail(targetEncodedBytes: 4_096)
            baseline.eventSequence = 10
            baseline.extensionPresentation.hostEpoch = "replay-host"
            baseline.extensionPresentation.revision = 0
            let store = SessionPresentationStore(client: client, performanceSignposts: SystemPerformanceSignposts.shared)
            let opening = Task { try await store.open(baseline.sessionId) }
            try await socket.waitUntilSent(count: 2)
            var frames = await socket.sentFrames()
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[1])
            let openID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                "result": .object(["session": try JSONValue.encode(baseline), "syncToken": .string("sync"), "subscriptionToken": .string("provisional")]),
            ])))
            try await socket.waitUntilSent(count: 3)
            await store.admit(GatewayEvent(
                type: "event", topic: "session.extensionPresentation", sessionId: baseline.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(baseline.runtimeGeneration), "eventSequence": .number(11), "revision": .number(Double(baseline.revision)),
                    "data": .object(["version": .number(3), "hostEpoch": .string("replay-host"), "revision": .number(2), "capabilities": .array([.string("gap")])]),
                ])
            ))
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[2])
            let syncID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(syncID), "ok": .bool(true), "result": .object(["synchronized": .bool(true)]),
            ])))
            try await socket.waitUntilSent(count: 4)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[3])
            #expect(request.objectValue?["method"]?.stringValue == "session.close")
            let closeID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(closeID), "ok": .bool(true), "result": .object(["closed": .bool(true)]),
            ])))
            try await socket.waitUntilSent(count: 5)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[4])
            #expect(request.objectValue?["method"]?.stringValue == "session.open")
            #expect(store.snapshot == nil)
            opening.cancel()
            _ = try? await opening.value
            await client.close()
        }
    }

    @Test("fresh-open replay publishes editor effects against the installed target")
    func freshOpenReplayEditorTarget() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let model = AppModel(
                client: client,
                cache: SnapshotCache(
                    root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                ),
                composerDraftStore: ComposerDraftStore(
                    root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                )
            )
            let connecting = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var snapshot = try SessionScenarioBuilder(seed: 90).openingTail(targetEncodedBytes: 4_096)
            snapshot.extensionPresentation.hostEpoch = "editor-host"
            snapshot.extensionPresentation.revision = 0
            let opening = Task { try await model.openSessionPresentation(snapshot.sessionId) }

            try await socket.waitUntilSent(count: 2)
            var frame = await socket.sentFrames()[1]
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            var requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(snapshot),
                    "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"),
                    "completionRevision": .number(13),
                ]),
            ])))

            try await socket.waitUntilSent(count: 3)
            await model.handle(GatewayEvent(
                type: "event",
                topic: "session.extensionPresentation",
                sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                    "revision": .number(Double(snapshot.revision + 1)),
                    "data": .object([
                        "version": .number(3), "hostEpoch": .string("editor-host"), "revision": .number(1),
                        "semantic": .object([
                            "editorAction": .string("set"), "editorDelta": .string("draft"),
                            "editorText": .string("draft"), "editorRevision": .number(1),
                        ]),
                    ]),
                ])
            ))
            #expect(model.presentationTarget(for: snapshot.sessionId) == nil)

            frame = await socket.sentFrames()[2]
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object(["synchronized": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: 3, expectedRevision: 13)

            let generation = try await opening.value
            let target = SessionPresentationIdentity(
                sessionID: snapshot.sessionId,
                generation: generation
            )
            let scope = try #require(model.composerDrafts.scope(for: target))
            #expect(model.composerDrafts.editorRequest(for: target) == nil)
            #expect(model.composerDrafts.text(for: scope) == "draft")
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.extensionPresentation.semanticState.editorText == "draft")
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.eventSequence == snapshot.eventSequence + 1)
            await model.teardown()
            await client.close()
        }
    }

    @Test("serialized editor updates use the newest authoritative base revision")
    func editorDebounceDoesNotRebase() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
            let model = AppModel(client: client, cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
            let connecting = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value
            var snapshot = try SessionScenarioBuilder(seed: 8_909).openingTail(targetEncodedBytes: 4_096)
            snapshot.extensionPresentation.hostEpoch = "debounce-host"
            snapshot.extensionPresentation.semanticState.editorRevision = 3
            snapshot.extensionPresentation.semanticState.editorText = "base"
            let opening = Task { try await model.openSessionPresentation(snapshot.sessionId) }
            try await socket.waitUntilSent(count: 2)
            var frames = await socket.sentFrames()
            var request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[1])
            let openID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(openID), "ok": .bool(true),
                "result": .object([
                    "session": try JSONValue.encode(snapshot),
                    "syncToken": .string("sync"),
                    "subscriptionToken": .string("subscription"),
                    "completionRevision": .number(14),
                ]),
            ])))
            try await socket.waitUntilSent(count: 3)
            frames = await socket.sentFrames()
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[2])
            let syncID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(syncID), "ok": .bool(true), "result": .object(["synchronized": .bool(true)]),
            ])))
            try await answerAttentionRead(socket, frameIndex: 3, expectedRevision: 14)
            let generation = try await opening.value
            let target = SessionPresentationIdentity(sessionID: snapshot.sessionId, generation: generation)
            frames = await socket.sentFrames()
            let sentBeforeEditorUpdate = frames.count
            model.scheduleExtensionEditorUpdate(target: target, text: "local-1")
            model.scheduleExtensionEditorUpdate(target: target, text: "local-2")
            await model.handle(GatewayEvent(
                type: "event", topic: "session.extensionPresentation", sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration), "eventSequence": .number(Double(snapshot.eventSequence + 1)), "revision": .number(Double(snapshot.revision)),
                    "data": .object(["version": .number(3), "hostEpoch": .string("debounce-host"), "revision": .number(1),
                        "semantic": .object(["editorAction": .string("set"), "editorDelta": .string("remote"), "editorText": .string("remote"), "editorRevision": .number(4)])]),
                ])
            ))
            model.scheduleExtensionEditorUpdate(target: target, text: "local")
            try await Task.sleep(for: .milliseconds(400))
            frames = await socket.sentFrames()
            let updateFrame = try #require(frames.dropFirst(sentBeforeEditorUpdate).first { frame in
                (try? JSONDecoder.gateway.decode(JSONValue.self, from: frame).objectValue?["method"]?.stringValue) == "extension.editor.update"
            })
            request = try JSONDecoder.gateway.decode(JSONValue.self, from: updateFrame)
            #expect(request.objectValue?["method"]?.stringValue == "extension.editor.update")
            #expect(request.objectValue?["params"]?.objectValue?["hostEpoch"]?.stringValue == "debounce-host")
            #expect(request.objectValue?["params"]?.objectValue?["baseRevision"]?.intValue == 4)
            #expect(request.objectValue?["params"]?.objectValue?["text"]?.stringValue == "local")
            let editorUpdates = frames.dropFirst(sentBeforeEditorUpdate).filter { frame in
                (try? JSONDecoder.gateway.decode(JSONValue.self, from: frame)
                    .objectValue?["method"]?.stringValue) == "extension.editor.update"
            }
            #expect(editorUpdates.count == 1)
            let updateID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(updateID), "ok": .bool(true),
                "result": .object(["applied": .bool(false), "revision": .number(4), "text": .string("remote")]),
            ])))
            await model.teardown()
            await client.close()
        }
    }

    @Test("paging keeps the authoritative tail immutable and rejects stale leases")
    func pagingRevalidatesLease() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var snapshot = try SessionScenarioBuilder(seed: 86).openingTail(targetEncodedBytes: 4_096)
            snapshot.transcript = Array(snapshot.transcript.prefix(1))
            snapshot.transcriptStart = 10
            snapshot.transcriptTotal = snapshot.transcript.count + 10
            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )

            func respond(
                index: Int,
                items: [TranscriptItem] = [],
                start: Int = 10,
                end: Int = 10,
                nextEntryId: String? = nil
            ) async throws {
                try await socket.waitUntilSent(count: index + 1)
                let frame = await socket.sentFrames()[index]
                let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
                let id = try #require(request.objectValue?["id"]?.stringValue)
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"),
                    "id": .string(id),
                    "ok": .bool(true),
                    "result": .object([
                        "items": try JSONValue.encode(items),
                        "start": .number(Double(start)),
                        "end": .number(Double(end)),
                        "total": .number(Double(snapshot.transcriptTotal ?? 10)),
                        "nextEntryId": (nextEntryId ?? snapshot.transcript.first.map { $0.id }).map(JSONValue.string) ?? .null,
                        "runtimeGeneration": .string(snapshot.runtimeGeneration),
                        "leafEntryId": snapshot.leafEntryId.map(JSONValue.string) ?? .null,
                    ]),
                ])))
            }

            store.installHostedSubscription(snapshot: snapshot, token: "current")
            var target = try #require(store.mountedTarget)
            let earlierItem = try #require(
                SessionScenarioBuilder(seed: 8_600).historyPage(count: 1, longRowBytes: 16).first
            )
            let loaded = Task {
                await store.loadEarlier(
                    sessionID: snapshot.sessionId,
                    presentationGeneration: target.generation
                )
            }
            try await socket.waitUntilSent(count: 2)
            try await respond(index: 1, items: [earlierItem], start: 9, end: 10)
            _ = await loaded.value
            #expect(store.snapshot?.transcriptStart == 10)
            #expect(store.visibleTranscriptStart == 9)
            #expect(store.visibleTranscript.first?.id == earlierItem.id)
            #expect(store.visibleTranscript.map(\.id) == [earlierItem.id] + snapshot.transcript.map(\.id))

            let returningWhileLoading = Task {
                await store.loadEarlier(
                    sessionID: snapshot.sessionId,
                    presentationGeneration: target.generation
                )
            }
            try await socket.waitUntilSent(count: 3)
            let streamingItem = try #require(snapshot.transcript.first)
            let secondEarlierItem = try #require(
                SessionScenarioBuilder(seed: 8_601).historyPage(count: 1, longRowBytes: 16).first
            )
            await store.admit(GatewayEvent(
                type: "event",
                topic: "session.progress",
                sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                    "revision": .number(Double(snapshot.revision + 1)),
                    "data": .object(["message": try JSONValue.encode(streamingItem)]),
                ])
            ))
            try await respond(index: 2, items: [secondEarlierItem], start: 8, end: 9, nextEntryId: earlierItem.id)
            #expect(await returningWhileLoading.value == .installed)
            #expect(store.snapshot?.transcriptStart == 10)
            #expect(store.visibleTranscriptStart == 8)
            #expect(store.visibleTranscript.map(\.id) == [secondEarlierItem.id, earlierItem.id] + snapshot.transcript.map(\.id))

            store.installHostedSubscription(snapshot: snapshot, token: "revoked")
            target = try #require(store.mountedTarget)
            let revoked = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 4)
            store.revokeIntake(target)
            try await respond(index: 3)
            _ = await revoked.value
            #expect(store.snapshot?.transcriptStart == 10)

            store.installHostedSubscription(snapshot: snapshot, token: "original")
            target = try #require(store.mountedTarget)
            let replaced = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 5)
            store.replaceHostedSubscriptionToken("replacement")
            try await respond(index: 4)
            _ = await replaced.value
            #expect(store.snapshot?.transcriptStart == 10)

            store.installHostedSubscription(snapshot: snapshot, token: "disconnect")
            target = try #require(store.mountedTarget)
            let disconnected = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 6)
            store.retireConnection()
            try await respond(index: 5)
            _ = await disconnected.value
            #expect(store.snapshot?.transcriptStart == 10)

            // A branch change while the page request is suspended invalidates
            // the captured structure lease immediately rather than retrying a
            // stale cursor.
            store.installHostedSubscription(snapshot: snapshot, token: "branch")
            target = try #require(store.mountedTarget)
            let branchChanged = Task {
                await store.loadEarlier(sessionID: snapshot.sessionId, presentationGeneration: target.generation)
            }
            try await socket.waitUntilSent(count: 7)
            await store.admit(GatewayEvent(
                type: "event",
                topic: "session.structureChanged",
                sessionId: snapshot.sessionId,
                payload: .object([
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "eventSequence": .number(Double(snapshot.eventSequence + 1)),
                    "revision": .number(Double(snapshot.revision + 1)),
                    "data": .object(["branchChanged": .bool(true)]),
                ])
            ))
            try await respond(index: 6, items: [earlierItem], start: 9, end: 10)
            #expect(await branchChanged.value == .stale)
            #expect(store.visibleTranscriptStart == 10)
            await client.close()
        }
    }

    @Test("paging admits projected neighbors separated by filtered canonical entries")
    func pagingAcrossFilteredCanonicalEntries() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
            )
            let profile = GatewayProfile(
                id: "gateway",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            )
            let connecting = Task { try await client.connect(profile: profile, token: "token") }
            try await socket.waitUntilSent(count: 1)
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
            _ = try await connecting.value

            var snapshot = try SessionScenarioBuilder(seed: 8_602).openingTail(targetEncodedBytes: 4_096)
            snapshot.transcript = Array(snapshot.transcript.suffix(1))
            snapshot.transcriptStart = 10
            snapshot.transcriptTotal = 11
            let nextID = try #require(snapshot.transcript.first?.id)

            var page = try SessionScenarioBuilder(seed: 8_603).historyPage(count: 2, longRowBytes: 16)
            let encodedSecond = try JSONValue.encode(page[1])
            var secondObject = try #require(encodedSecond.objectValue)
            secondObject["parentId"] = .string("filtered-canonical-entry")
            page[1] = try JSONDecoder.gateway.decode(
                TranscriptItem.self,
                from: JSONEncoder.gateway.encode(JSONValue.object(secondObject))
            )
            #expect(page[1].parentId != page[0].id)
            #expect(snapshot.transcript.first?.parentId != page[1].id)

            let store = SessionPresentationStore(
                client: client,
                performanceSignposts: SystemPerformanceSignposts.shared
            )
            store.installHostedSubscription(snapshot: snapshot, token: "current")
            let target = try #require(store.mountedTarget)
            let loading = Task {
                await store.loadEarlier(
                    sessionID: snapshot.sessionId,
                    presentationGeneration: target.generation
                )
            }
            try await socket.waitUntilSent(count: 2)
            let request = try JSONDecoder.gateway.decode(
                JSONValue.self,
                from: await socket.sentFrames()[1]
            )
            let requestID = try #require(request.objectValue?["id"]?.stringValue)
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": .object([
                    "items": try JSONValue.encode(page),
                    "start": .number(8),
                    "end": .number(10),
                    "total": .number(11),
                    "nextEntryId": .string(nextID),
                    "runtimeGeneration": .string(snapshot.runtimeGeneration),
                    "leafEntryId": snapshot.leafEntryId.map(JSONValue.string) ?? .null,
                ]),
            ])))

            #expect(await loading.value == .installed)
            #expect(store.snapshot?.transcriptStart == 10)
            #expect(store.visibleTranscriptStart == 8)
            #expect(store.visibleTranscript.map(\.id) == page.map(\.id) + snapshot.transcript.map(\.id))
            await client.close()
        }
    }


    @Test("subscription and paging admissions require every captured identity")
    func exactAdmissionMatrices() throws {
        let snapshot = try SessionScenarioBuilder(seed: 89).openingTail(targetEncodedBytes: 4_096)
        let store = SessionPresentationStore(
            client: GatewayClient(),
            performanceSignposts: SystemPerformanceSignposts.shared
        )
        store.installHostedSubscription(snapshot: snapshot, token: "export-token")
        #expect(store.ownsInstalledSubscription(
            sessionID: snapshot.sessionId,
            token: "export-token"
        ))
        store.revokeIntake(try #require(store.target))
        #expect(!store.ownsInstalledSubscription(
            sessionID: snapshot.sessionId,
            token: "export-token"
        ))

        #expect(SessionPresentationStore.ownsSubscription(
            sessionID: "session",
            subscribedSessionID: "session",
            installedToken: "new",
            requestedToken: "new"
        ))
        #expect(!SessionPresentationStore.ownsSubscription(
            sessionID: "session",
            subscribedSessionID: "session",
            installedToken: "new",
            requestedToken: "stale"
        ))

        #expect(SessionPresentationStore.admitsTranscriptPageAnchor(
            expectedNextEntryID: "first",
            echoedNextEntryID: "first"
        ))
        #expect(!SessionPresentationStore.admitsTranscriptPageAnchor(
            expectedNextEntryID: "first",
            echoedNextEntryID: "wrong"
        ))
        #expect(!SessionPresentationStore.admitsTranscriptPageAnchor(
            expectedNextEntryID: "first",
            echoedNextEntryID: nil
        ))
        #expect(SessionPresentationStore.admitsTranscriptPageAnchor(
            expectedNextEntryID: nil,
            echoedNextEntryID: nil
        ))
        #expect(SessionPresentationStore.admitsTranscriptPageAnchor(
            expectedNextEntryID: nil,
            echoedNextEntryID: "gateway-projected-neighbor"
        ))

        let request = ChatTranscriptPageRequest(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            before: 20,
            expectedTotal: 28,
            expectedNextEntryID: "first"
        )
        #expect(request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "other",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 5,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "replacement",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 19,
            transcriptTotal: 28,
            firstTranscriptID: "first"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 28,
            firstTranscriptID: "replacement"
        ))
        #expect(!request.canInstall(
            sessionID: "session",
            presentationGeneration: 4,
            runtimeGeneration: "runtime",
            transcriptStart: 20,
            transcriptTotal: 27,
            firstTranscriptID: "first"
        ))
        #expect(request.canInstallPage(
            start: 12, end: 20, total: 28, itemCount: 8, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 19, total: 28, itemCount: 7, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 28, itemCount: 7, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: -1, end: 20, total: 28, itemCount: 21, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 0, end: 20, total: 28, itemCount: 513, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 27, itemCount: 8, visibleItemCount: 8
        ))
        #expect(!request.canInstallPage(
            start: 12, end: 20, total: 29, itemCount: 8, visibleItemCount: 8
        ))
    }
}

@MainActor
private final class NoticeScopeProbe: SessionPresentationStoreDelegate {
    var postedScopes: [InAppNoticeScope] = []
    var postedRoles: [InAppNoticeCenter.Role] = []
    var retiredScopes: [InAppNoticeScope] = []

    func sessionPresentationStoreDidRequestCatalogRefresh() {}
    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationIdentity,
        action: SessionEditorAction,
        text: String,
        fullText: String,
        revision: Int,
        operationID: String?
    ) {}
    func sessionPresentationStoreDidOpen(_ target: SessionPresentationIdentity) {}
    func sessionPresentationStoreDidPublishSnapshot(_ snapshot: SessionSnapshot, target: SessionPresentationIdentity) {}
    func sessionPresentationStorePostNotice(
        _ message: String,
        replacing key: InAppNoticeKey?,
        role: InAppNoticeCenter.Role,
        scope: InAppNoticeScope?
    ) {
        if let scope { postedScopes.append(scope) }
        postedRoles.append(role)
    }
    func sessionPresentationStoreRemoveNotice(_ key: InAppNoticeKey, scope: InAppNoticeScope?) {}
    func sessionPresentationStoreRetireNoticeScope(_ scope: InAppNoticeScope) { retiredScopes.append(scope) }
    func sessionPresentationStoreSurface(_ error: Error) {}
    func sessionPresentationStoreCheckpointCache() {}
}

@MainActor
private final class SecondaryErrorProbe: SessionPresentationStoreDelegate {
    var errors: [String] = []

    func sessionPresentationStoreDidRequestCatalogRefresh() {}
    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationIdentity,
        action: SessionEditorAction,
        text: String,
        fullText: String,
        revision: Int,
        operationID: String?
    ) {}
    func sessionPresentationStoreDidOpen(_ target: SessionPresentationIdentity) {}
    func sessionPresentationStoreDidPublishSnapshot(
        _ snapshot: SessionSnapshot,
        target: SessionPresentationIdentity
    ) {}
    func sessionPresentationStorePostNotice(
        _ message: String,
        replacing key: InAppNoticeKey?,
        role: InAppNoticeCenter.Role,
        scope: InAppNoticeScope?
    ) {}
    func sessionPresentationStoreRemoveNotice(_ key: InAppNoticeKey, scope: InAppNoticeScope?) {}
    func sessionPresentationStoreRetireNoticeScope(_ scope: InAppNoticeScope) {}
    func sessionPresentationStoreSurface(_ error: Error) { errors.append(error.localizedDescription) }
    func sessionPresentationStoreCheckpointCache() {}
}

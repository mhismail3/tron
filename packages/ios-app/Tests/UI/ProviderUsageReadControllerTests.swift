import Testing
@testable import TronMobile

@Suite("Provider usage read lifecycle")
@MainActor
struct ProviderUsageReadControllerTests {
    @Test("list usage admits only the newest delayed read")
    func supersededListReadCannotPublish() async throws {
        let owner = ProviderUsageReadController()
        var firstContinuation: CheckedContinuation<ProviderUsageResponse, Error>?
        var secondContinuation: CheckedContinuation<ProviderUsageResponse, Error>?
        let active = true
        let first = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: nil),
                fetch: { try await withCheckedThrowingContinuation { firstContinuation = $0 } },
                current: { active }
            )
        }
        while firstContinuation == nil { await Task.yield() }
        owner.begin()
        let second = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: nil),
                fetch: { try await withCheckedThrowingContinuation { secondContinuation = $0 } },
                current: { active }
            )
        }
        while secondContinuation == nil { await Task.yield() }
        secondContinuation?.resume(returning: response(providerID: "new-account"))
        await second.value
        firstContinuation?.resume(returning: response(providerID: "old-account"))
        await first.value
        #expect(owner.snapshots["new-account"]?.providerId == "new-account")
        #expect(owner.snapshots["old-account"] == nil)
    }

    @Test("detail usage rejects profile and dismissal results, then accepts reappearance")
    func detailLifecycleFencesDelayedReads() async throws {
        let owner = ProviderUsageReadController()
        var continuation: CheckedContinuation<ProviderUsageResponse, Error>?
        var active = true
        let first = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: "openrouter", profileRevision: 1),
                fetch: { try await withCheckedThrowingContinuation { continuation = $0 } },
                current: { active }
            )
        }
        while continuation == nil { await Task.yield() }
        active = false
        owner.begin(clear: true)
        continuation?.resume(returning: response(providerID: "openrouter"))
        await first.value
        #expect(owner.snapshots.isEmpty)

        active = true
        let reappearance = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: "openrouter", profileRevision: 2),
                fetch: { response(providerID: "openrouter") },
                current: { active }
            )
        }
        await reappearance.value
        #expect(owner.snapshots["openrouter"]?.providerId == "openrouter")
    }

    @Test("detail rejection exposes failure only for the admitted request")
    func detailFailureIsFenced() async throws {
        let owner = ProviderUsageReadController()
        var continuation: CheckedContinuation<ProviderUsageResponse, Error>?
        let read = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: "zai"),
                fetch: { try await withCheckedThrowingContinuation { continuation = $0 } },
                current: { true }
            )
        }
        while continuation == nil { await Task.yield() }
        continuation?.resume(throwing: FixtureError.rejected)
        await read.value
        #expect(owner.didFail)
        #expect(!owner.isLoading)
    }

    @Test("cancelled list/detail reads cannot change replacement loading, errors, or values", arguments: [false, true], [false, true])
    func cancelledReadCannotPublish(detail: Bool, reject: Bool) async throws {
        let owner = ProviderUsageReadController()
        let providerID: String? = detail ? "openrouter" : nil
        var oldContinuation: CheckedContinuation<ProviderUsageResponse, Error>?
        var newContinuation: CheckedContinuation<ProviderUsageResponse, Error>?
        let oldRead = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: providerID),
                fetch: { try await withCheckedThrowingContinuation { oldContinuation = $0 } },
                current: { true }
            )
        }
        try await withTestWatchdog(timeout: .seconds(3)) { @MainActor in
            while oldContinuation == nil {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        oldRead.cancel()
        // Mirrors dismissal/account invalidation, followed by a new presentation.
        owner.begin(clear: true)
        let newRead = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: providerID, profileRevision: 2),
                fetch: { try await withCheckedThrowingContinuation { newContinuation = $0 } },
                current: { true }
            )
        }
        try await withTestWatchdog(timeout: .seconds(3)) { @MainActor in
            while newContinuation == nil {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        if reject {
            oldContinuation?.resume(throwing: FixtureError.rejected)
        } else {
            oldContinuation?.resume(returning: response(providerID: "old-account"))
        }
        await oldRead.value
        #expect(owner.isLoading)
        #expect(!owner.didFail)
        #expect(owner.snapshots.isEmpty)
        newContinuation?.resume(returning: response(providerID: "openrouter"))
        await newRead.value
        #expect(!owner.isLoading)
        #expect(!owner.didFail)
        #expect(owner.snapshots["openrouter"] != nil)
        #expect(owner.snapshots["old-account"] == nil)
    }

    @Test("retiring a covered parent keeps its mounted row usage until a replacement admits")
    func coveredParentRetainsMountedSnapshot() async throws {
        let owner = ProviderUsageReadController()
        await owner.read(
            identity: identity(owner: owner, providerID: "openrouter"),
            fetch: { response(providerID: "openrouter") }, current: { true }
        )
        var continuation: CheckedContinuation<ProviderUsageResponse, Error>?
        let delayed = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: nil),
                fetch: { try await withCheckedThrowingContinuation { continuation = $0 } },
                current: { true }
            )
        }
        while continuation == nil { await Task.yield() }
        owner.begin()
        #expect(owner.snapshots["openrouter"] != nil)
        continuation?.resume(returning: response(providerID: "stale-list"))
        await delayed.value
        #expect(owner.snapshots["openrouter"] != nil)
        #expect(owner.snapshots["stale-list"] == nil)
    }

    @Test("a changed provider target rejects the old detail response")
    func changedTargetRejectsDelayedDetail() async throws {
        let owner = ProviderUsageReadController()
        var currentTarget = ProviderCatalogTarget.global
        var continuation: CheckedContinuation<ProviderUsageResponse, Error>?
        let read = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: "openrouter"),
                fetch: { try await withCheckedThrowingContinuation { continuation = $0 } },
                current: { currentTarget == .global }
            )
        }
        while continuation == nil { await Task.yield() }
        currentTarget = .session(id: "other")
        owner.begin(clear: true)
        continuation?.resume(returning: response(providerID: "openrouter"))
        await read.value
        #expect(owner.snapshots.isEmpty)
    }

    @Test("an admitted empty detail result removes previous account measurements")
    func emptyDetailDoesNotRestoreOldSnapshot() async {
        let owner = ProviderUsageReadController()
        await owner.read(
            identity: identity(owner: owner, providerID: "openrouter"),
            fetch: { response(providerID: "openrouter") }, current: { true }
        )
        #expect(owner.snapshots["openrouter"] != nil)
        owner.begin()
        await owner.read(
            identity: identity(owner: owner, providerID: "openrouter"),
            fetch: { ProviderUsageResponse(providers: []) }, current: { true }
        )
        #expect(owner.snapshots.isEmpty)
        #expect(!owner.isLoading)
        #expect(!owner.didFail)
    }

    @Test("settlement fences the loading placeholder on success and failure")
    func resolvedStateTracksSettlement() async {
        let owner = ProviderUsageReadController()
        var continuation: CheckedContinuation<ProviderUsageResponse, Error>?
        #expect(!owner.hasResolved)
        let read = Task {
            await owner.read(
                identity: identity(owner: owner, providerID: "openrouter"),
                fetch: { try await withCheckedThrowingContinuation { continuation = $0 } },
                current: { true }
            )
        }
        while continuation == nil { await Task.yield() }
        #expect(owner.isLoading)
        #expect(!owner.hasResolved)
        continuation?.resume(returning: response(providerID: "openrouter"))
        await read.value
        #expect(owner.hasResolved)
        #expect(!owner.didFail)

        owner.begin(clear: true)
        #expect(!owner.hasResolved)
        await owner.read(
            identity: identity(owner: owner, providerID: "openrouter"),
            fetch: { throw FixtureError.rejected }, current: { true }
        )
        #expect(owner.hasResolved)
        #expect(owner.didFail)
    }

    private func identity(
        owner: ProviderUsageReadController,
        providerID: String?,
        profileRevision: Int = 1
    ) -> ProviderUsageReadIdentity {
        ProviderUsageReadIdentity(
            target: .global, providerID: providerID, profileRevision: profileRevision,
            profileID: "fixture-profile", invalidationGeneration: 1,
            foregroundGeneration: 1, requestGeneration: owner.requestGeneration,
            presentationActive: true
        )
    }

    private func response(providerID: String) -> ProviderUsageResponse {
        ProviderUsageResponse(providers: [ProviderUsageSnapshot(providerId: providerID, status: .available)])
    }

    private enum FixtureError: Error { case rejected }
}
import Foundation

extension SessionContextSheet {
    func observeSessionContext() async {
        refreshCoordinator.reset()
        defer { refreshCoordinator.reset() }
        await loadCachedContextOverview()
        guard isConnected else { return }

        // The compact provider inventory is the only eager network projection.
        // Delivery and worker sections activate when their LazyVStack rows
        // actually become visible.
        requestProviderContextRefresh()

        // Worker and delivery state can change throughout an active run. The
        // provider-context audit is immutable once written, so reread it only
        // on open/foreground and once when activity settles instead of moving
        // a large manifest across the connection every second.
        var wasActive = shouldContinueObservingDeliveryState
        while !Task.isCancelled, isConnected {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let isActive = shouldContinueObservingDeliveryState
            if isActive {
                requestActivatedLiveSessionStateRefreshes()
            } else if wasActive {
                requestActivatedLiveSessionStateRefreshes()
                requestProviderContextRefresh()
            }
            wasActive = isActive
        }
    }

    func requestActivatedSessionContextRefreshes() {
        guard isConnected else { return }
        requestProviderContextRefresh()
        requestActivatedLiveSessionStateRefreshes()
    }

    func requestActivatedLiveSessionStateRefreshes() {
        guard isConnected else { return }
        if workerLaneActivated {
            requestWorkerRefresh()
        }
        if agentUpdatesLaneActivated {
            requestAgentUpdatesRefresh()
        }
    }

    func activateAgentUpdatesLane() {
        guard !agentUpdatesLaneActivated else { return }
        agentUpdatesLaneActivated = true
        requestAgentUpdatesRefresh()
    }

    func activateWorkerLane() {
        guard !workerLaneActivated else { return }
        workerLaneActivated = true
        requestWorkerRefresh()
    }

    func requestAgentUpdatesRefresh() {
        guard isConnected else { return }
        refreshCoordinator.request(.agentUpdates) { generation in
            await loadAgentUpdates(generation: generation)
        }
    }

    func requestProviderContextRefresh() {
        guard isConnected else { return }
        refreshCoordinator.request(.providerContext) { generation in
            await loadInspectableContext(generation: generation)
        }
    }

    func requestWorkerRefresh(loadOlder: Bool = false) {
        guard isConnected else { return }
        if loadOlder {
            loadOlderWorkerRunsPending = true
        }
        refreshCoordinator.request(.workers) { generation in
            let shouldLoadOlder = loadOlderWorkerRunsPending
            loadOlderWorkerRunsPending = false
            await loadSessionWorkerRuns(
                reset: !shouldLoadOlder,
                generation: generation
            )
        }
    }

    func loadAgentUpdates(generation: UInt64) async {
        guard refreshCoordinator.isCurrent(generation), isConnected else { return }
        agentUpdatesLoadingGeneration = generation
        isLoadingAgentUpdates = true
        defer {
            if agentUpdatesLoadingGeneration == generation {
                agentUpdatesLoadingGeneration = nil
                isLoadingAgentUpdates = false
            }
        }
        do {
            let result = try await sessionRepository.agentUpdates(
                sessionId: sessionId,
                limit: 100
            )
            guard refreshCoordinator.isCurrent(generation) else { return }
            agentUpdates = result.updates
            agentWaits = result.waits
            hasLoadedAgentUpdatesSnapshot = true
            agentUpdatesLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard refreshCoordinator.isCurrent(generation) else { return }
            guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
            agentUpdatesLoadError = !hasLoadedAgentUpdatesSnapshot
                ? "Delivery and wait status could not load: \(error.localizedDescription)"
                : "Couldn’t refresh delivery and wait status; showing the last update."
        }
    }

    func loadInspectableContext(generation: UInt64) async {
        guard refreshCoordinator.isCurrent(generation), isConnected else { return }
        contextLoadingGeneration = generation
        isLoadingInspectableContext = true
        defer {
            if contextLoadingGeneration == generation {
                contextLoadingGeneration = nil
                isLoadingInspectableContext = false
            }
        }
        do {
            let page = try await sessionRepository.contextRequests(
                sessionId: sessionId,
                beforeSequence: nil,
                limit: 1
            )
            guard refreshCoordinator.isCurrent(generation) else { return }
            let refreshedSummary = page.requests.first
            if latestContextSummary?.eventId != refreshedSummary?.eventId {
                contextDetailLoadingGeneration &+= 1
                contextDetailLoadingDestination = nil
                latestContextDetails.removeAll()
            }
            latestContextSummary = refreshedSummary
            storeCachedContextOverview(refreshedSummary)
            contextLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard refreshCoordinator.isCurrent(generation) else { return }
            guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
            if latestContextSummary == nil {
                contextLoadError = "Context audit could not load: \(error.localizedDescription)"
            } else {
                contextLoadError = "Couldn’t refresh model context; showing the last update."
            }
        }
    }

    func loadCachedContextOverview() async {
        do {
            guard let summary = try await cachedSessionRepository
                .getContextSummary(sessionId) else { return }
            guard !Task.isCancelled else { return }
            latestContextSummary = summary
            contextLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            logger.warning(
                "Could not restore cached Session Context summary: \(error.localizedDescription)",
                category: .database
            )
        }
    }

    func storeCachedContextOverview(_ summary: SessionContextRequestSummaryDTO?) {
        let repository = cachedSessionRepository
        let sessionId = sessionId
        Task {
            do {
                try await repository.storeContextSummary(summary, sessionId: sessionId)
            } catch {
                logger.warning(
                    "Could not cache Session Context summary: \(error.localizedDescription)",
                    category: .database
                )
            }
        }
    }

    func openContextDetail(_ destination: SessionContextDetailDestination) {
        guard let summary = latestContextSummary else { return }
        if let detail = latestContextDetails[destination], detail.eventId == summary.eventId {
            selectedContextDetail = contextDetailSelection(
                destination,
                detail: detail
            )
            return
        }
        guard contextDetailLoadingDestination == nil else { return }

        contextDetailLoadingGeneration &+= 1
        let generation = contextDetailLoadingGeneration
        contextDetailLoadingDestination = destination
        Task {
            defer {
                if contextDetailLoadingGeneration == generation {
                    contextDetailLoadingDestination = nil
                }
            }
            do {
                let detail = try await sessionRepository.contextRequestDetail(
                    sessionId: sessionId,
                    eventId: summary.eventId,
                    projection: destination == .agentContext ? .agentContext : .technical
                )
                guard !Task.isCancelled,
                      contextDetailLoadingGeneration == generation,
                      latestContextSummary?.eventId == detail.eventId else { return }
                latestContextDetails[destination] = detail
                selectedContextDetail = contextDetailSelection(
                    destination,
                    detail: detail
                )
            } catch is CancellationError {
                return
            } catch {
                guard contextDetailLoadingGeneration == generation else { return }
                errorMessage = "Could not inspect model context: \(error.localizedDescription)"
            }
        }
    }

    func contextDetailSelection(
        _ destination: SessionContextDetailDestination,
        detail: SessionContextRequestDetailDTO
    ) -> SessionContextDetailSelection {
        switch destination {
        case .agentContext:
            return .agentContext(detail)
        case .technical:
            return .technical(
                detail,
                cacheReadTokens: contextState.accumulatedCacheReadTokens,
                cacheWriteTokens: contextState.accumulatedCacheCreationTokens
            )
        }
    }

    func loadModels() async {
        if availableModels.isEmpty {
            availableModels = modelRepository.cachedModels
        }
        guard isConnected else { return }

        modelLoadingGeneration &+= 1
        let generation = modelLoadingGeneration
        isLoadingModels = true
        defer {
            if generation == modelLoadingGeneration {
                isLoadingModels = false
            }
        }
        do {
            let models = try await modelRepository.list(forceRefresh: false)
            guard !Task.isCancelled,
                  generation == modelLoadingGeneration else { return }
            availableModels = models
        } catch is CancellationError {
            return
        } catch {
            guard generation == modelLoadingGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                errorMessage = "Could not load models: \(error.localizedDescription)"
            }
        }
    }

    func loadSessionWorkerRuns(reset: Bool, generation: UInt64) async {
        guard refreshCoordinator.isCurrent(generation), isConnected else { return }
        workerLoadingGeneration = generation
        isLoadingWorkerRuns = true
        defer {
            if workerLoadingGeneration == generation {
                workerLoadingGeneration = nil
                isLoadingWorkerRuns = false
            }
        }
        do {
            let catalogRevision = workerCatalogRevision
            let shouldRefreshNames = workerNames.isEmpty
                || loadedWorkerCatalogRevision != catalogRevision
            let page = try await workerRepository.workerRunGraphs(
                originSessionId: sessionId,
                limit: 10,
                offset: reset ? nil : workerRunsNextOffset
            )
            guard refreshCoordinator.isCurrent(generation) else { return }
            if reset {
                sessionWorkerRuns = page.runs
            } else {
                var identifiers = Set(sessionWorkerRuns.map(\.invocationId))
                sessionWorkerRuns.append(contentsOf: page.runs.filter {
                    identifiers.insert($0.invocationId).inserted
                })
            }
            workerRunsNextOffset = page.nextOffset
            workerLoadError = nil

            // Names are cosmetic. Publish the authoritative run graph before
            // resolving them so a
            // slow catalog cannot hold the entire section in a loading state.
            if shouldRefreshNames,
               let workers = try? await workerRepository.workers(includeRetired: true).workers,
               refreshCoordinator.isCurrent(generation) {
                workerNames = Dictionary(
                    uniqueKeysWithValues: workers.map { ($0.workerId, $0.name) }
                )
                loadedWorkerCatalogRevision = catalogRevision
            }
        } catch is CancellationError {
            return
        } catch {
            guard refreshCoordinator.isCurrent(generation) else { return }
            guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
            workerLoadError = sessionWorkerRuns.isEmpty
                ? "Worker activity could not load: \(error.localizedDescription)"
                : "Couldn’t refresh worker activity; showing the last update."
        }
    }

    func loadOlderSessionWorkerRuns() {
        requestWorkerRefresh(loadOlder: true)
    }

    func forkSession() async {
        guard canMutate else { return }
        isForking = true
        defer { isForking = false }
        do {
            let newSessionId = try await onFork()
            dismiss()
            await Task.yield()
            NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Could not fork session: \(error.localizedDescription)"
        }
    }
}

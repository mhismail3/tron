import Foundation

extension SessionContextSheet {
    func observeSessionContext() async {
        refreshCoordinator.reset()
        defer { refreshCoordinator.reset() }
        guard isConnected else {
            loadCachedInspectableContext()
            return
        }

        requestAllSessionContextRefreshes()
        // The three stores are intentionally independent. Force one settled
        // reread after the initial parallel snapshot so a terminal worker and
        // its subsequently imported delivery cannot straddle sheet opening.
        var wasActive = true
        while !Task.isCancelled, isConnected {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            let isActive = shouldContinueObservingDeliveryState
            if isActive || wasActive {
                requestAllSessionContextRefreshes()
            }
            wasActive = isActive
        }
    }

    func requestAllSessionContextRefreshes() {
        guard isConnected else { return }
        requestWorkerRefresh()
        requestAgentUpdatesRefresh()
        requestProviderContextRefresh()
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
                limit: 10
            )
            var detail = latestContextDetail
            if let latest = page.requests.first,
               latestContextDetail?.eventId != latest.eventId {
                detail = try await sessionRepository.contextRequestDetail(
                    sessionId: sessionId,
                    eventId: latest.eventId
                )
            }
            guard refreshCoordinator.isCurrent(generation) else { return }
            contextRequests = page.requests
            contextRequestsNextSequence = page.nextBeforeSequence
            latestContextDetail = detail
            contextLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard refreshCoordinator.isCurrent(generation) else { return }
            if contextRequests.isEmpty {
                loadCachedInspectableContext()
            }
            if contextRequests.isEmpty {
                contextLoadError = "Context audit could not load: \(error.localizedDescription)"
            } else {
                contextLoadError = "Couldn’t refresh model context; showing the last update."
            }
        }
    }

    func loadCachedInspectableContext() {
        let events = cachedProviderRequestEvents.sorted { $0.sequence > $1.sequence }
        guard !events.isEmpty else { return }
        contextRequests = events.map { event in
            let format = event.payload.string("format") ?? "unknown"
            let manifestValue = event.payload["contextManifest"]
            let automaticCount = manifestValue?
                .dictionaryValue?["automaticContext"]
                .flatMap { AnyCodable($0).arrayValue }?
                .count ?? 0
            return SessionContextRequestSummaryDTO(
                eventId: event.id,
                sequence: Int64(event.sequence),
                timestamp: event.timestamp,
                format: format,
                turn: event.payload.int("turn").map(UInt64.init),
                providerType: event.payload.string("providerType"),
                providerName: event.payload.string("providerName"),
                model: event.payload.string("model"),
                requestClassification: event.payload.string("requestClassification") ?? "legacy",
                messageCount: UInt64(max(event.payload.int("messageCount") ?? 0, 0)),
                toolCount: UInt64(max(event.payload.int("toolCount") ?? 0, 0)),
                automaticContextCount: UInt64(automaticCount),
                manifestAvailable: manifestValue?.isNull == false,
                provenanceAvailability: [
                    "tron.model_provider_request.v3",
                    "tron.model_provider_request.v4",
                ].contains(format)
                    ? "complete"
                    : "legacy_unavailable"
            )
        }
        contextRequestsNextSequence = nil
        if let event = events.first {
            let manifest = event.payload["contextManifest"].flatMap { value in
                try? JSONDecoder().decode(
                    SessionContextManifestDTO.self,
                    from: JSONEncoder().encode(value)
                )
            }
            latestContextDetail = SessionContextRequestDetailDTO(
                eventId: event.id,
                sequence: Int64(event.sequence),
                timestamp: event.timestamp,
                format: event.payload.string("format") ?? "unknown",
                contextManifest: manifest,
                providerAdditions: event.payload["providerAdditions"].flatMap { value in
                    try? JSONDecoder().decode(
                        [ContextSystemContributionDTO].self,
                        from: JSONEncoder().encode(value)
                    )
                },
                providerAudit: AnyCodable(event.payload.mapValues(\.value)),
                provenanceAvailability: [
                    "tron.model_provider_request.v3",
                    "tron.model_provider_request.v4",
                ].contains(event.payload.string("format") ?? "")
                    ? "complete"
                    : "legacy_unavailable"
            )
        }
        contextLoadError = nil
    }

    func loadOlderContextRequests() async {
        guard let beforeSequence = contextRequestsNextSequence else { return }
        do {
            let page = try await sessionRepository.contextRequests(
                sessionId: sessionId,
                beforeSequence: beforeSequence,
                limit: 10
            )
            var identifiers = Set(contextRequests.map(\.eventId))
            contextRequests.append(contentsOf: page.requests.filter {
                identifiers.insert($0.eventId).inserted
            })
            contextRequestsNextSequence = page.nextBeforeSequence
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Could not load older model requests: \(error.localizedDescription)"
        }
    }

    func selectContextRequest(_ request: SessionContextRequestSummaryDTO) async {
        do {
            latestContextDetail = try await sessionRepository.contextRequestDetail(
                sessionId: sessionId,
                eventId: request.eventId
            )
            if let index = contextRequests.firstIndex(where: { $0.eventId == request.eventId }) {
                let selected = contextRequests.remove(at: index)
                contextRequests.insert(selected, at: 0)
            }
            showContextHistory = false
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Could not inspect this model request: \(error.localizedDescription)"
        }
    }

    func loadModels() async {
        availableModels = modelRepository.cachedModels
        guard availableModels.isEmpty, isConnected else { return }

        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await modelRepository.list(forceRefresh: false)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Could not load models: \(error.localizedDescription)"
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
            var refreshedWorkerNames = workerNames
            let catalogRevision = workerCatalogRevision
            if workerNames.isEmpty || loadedWorkerCatalogRevision != catalogRevision {
                let workers = try await workerRepository.workers(includeRetired: true).workers
                refreshedWorkerNames = Dictionary(
                    uniqueKeysWithValues: workers.map { ($0.workerId, $0.name) }
                )
            }
            let page = try await workerRepository.workerRunGraphs(
                originSessionId: sessionId,
                limit: 10,
                offset: reset ? nil : workerRunsNextOffset
            )
            guard refreshCoordinator.isCurrent(generation) else { return }
            workerNames = refreshedWorkerNames
            loadedWorkerCatalogRevision = catalogRevision
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
        } catch is CancellationError {
            return
        } catch {
            guard refreshCoordinator.isCurrent(generation) else { return }
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

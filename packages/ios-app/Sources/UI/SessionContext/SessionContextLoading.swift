import Foundation

extension SessionContextSheet {
    func observeInspectableContext() async {
        await loadInspectableContext()
        await loadAgentUpdates()
        while !Task.isCancelled, isConnected, isAgentActive {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await loadInspectableContext()
            await loadAgentUpdates()
        }
        if !Task.isCancelled, isConnected {
            await loadInspectableContext()
            await loadAgentUpdates()
        }
    }

    func loadAgentUpdates() async {
        guard !isLoadingAgentUpdates, isConnected else { return }
        isLoadingAgentUpdates = true
        defer { isLoadingAgentUpdates = false }
        do {
            let result = try await sessionRepository.agentUpdates(
                sessionId: sessionId,
                limit: 100
            )
            agentUpdates = result.updates
            agentWaits = result.waits
            agentUpdatesLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            agentUpdatesLoadError = "Agent updates could not load: \(error.localizedDescription)"
        }
    }

    func loadInspectableContext() async {
        guard !isLoadingInspectableContext else { return }
        guard isConnected else {
            loadCachedInspectableContext()
            return
        }
        isLoadingInspectableContext = true
        defer { isLoadingInspectableContext = false }
        do {
            let page = try await sessionRepository.contextRequests(
                sessionId: sessionId,
                beforeSequence: nil,
                limit: 10
            )
            contextRequests = page.requests
            contextRequestsNextSequence = page.nextBeforeSequence
            if let latest = page.requests.first,
               latestContextDetail?.eventId != latest.eventId {
                latestContextDetail = try await sessionRepository.contextRequestDetail(
                    sessionId: sessionId,
                    eventId: latest.eventId
                )
            }
            contextLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            if contextRequests.isEmpty {
                loadCachedInspectableContext()
            }
            if contextRequests.isEmpty {
                contextLoadError = "Context audit could not load: \(error.localizedDescription)"
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
        } catch {
            errorMessage = "Could not load models: \(error.localizedDescription)"
        }
    }

    func observeSessionWorkers() async {
        await loadSessionWorkerRuns(reset: true)
        while !Task.isCancelled,
              isAgentActive || sessionWorkerRuns.contains(where: { $0.status == "queued" || $0.status == "running" }) {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await loadSessionWorkerRuns(reset: true)
        }
    }

    func loadSessionWorkerRuns(reset: Bool) async {
        guard !isLoadingWorkerRuns else { return }
        isLoadingWorkerRuns = true
        defer { isLoadingWorkerRuns = false }
        do {
            if workerNames.isEmpty {
                let workers = try await workerRepository.workers(includeRetired: true).workers
                workerNames = Dictionary(uniqueKeysWithValues: workers.map { ($0.workerId, $0.name) })
            }
            let page = try await workerRepository.workerRunGraphs(
                originSessionId: sessionId,
                limit: 10,
                offset: reset ? nil : workerRunsNextOffset
            )
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
        } catch {
            workerLoadError = "Worker activity could not load: \(error.localizedDescription)"
        }
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
        } catch {
            errorMessage = "Could not fork session: \(error.localizedDescription)"
        }
    }
}

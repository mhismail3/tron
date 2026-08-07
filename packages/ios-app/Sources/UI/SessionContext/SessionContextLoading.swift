import Foundation

/// One already-reconstructed provider audit, reduced to a cheap overview for
/// immediate sheet presentation. The full manifest is decoded off MainActor
/// only to warm detail navigation; no second device cache is created.
struct CachedSessionContextEvent: Sendable {
    let eventId: String
    let sequence: Int64
    let timestamp: String
    let payload: AnyCodable

    init(_ event: RawEvent) {
        eventId = event.id
        sequence = Int64(event.sequence)
        timestamp = event.timestamp
        payload = AnyCodable(event.payload.mapValues(\.value))
    }

    var summary: SessionContextRequestSummaryDTO {
        let root = payload.dictionaryValue ?? [:]
        let manifestValue = root["contextManifest"].map(AnyCodable.init)
        let manifest = manifestValue?.dictionaryValue
        let messages = manifest?["messages"].map(AnyCodable.init)?.arrayValue ?? []
        let systemContributions = manifest?["systemContributions"]
            .map(AnyCodable.init)?.arrayValue ?? []
        let providerAdditions = root["providerAdditions"]
            .map(AnyCodable.init)?.arrayValue ?? []
        let automaticContext = manifest?["automaticContext"]
            .map(AnyCodable.init)?.arrayValue ?? []
        let agentDeliveries = manifest?["agentDeliveries"]
            .map(AnyCodable.init)?.arrayValue ?? []
        let attachmentCount = messages.filter { message in
            let kinds = AnyCodable(message).dictionaryValue?["contentKinds"]
                .map(AnyCodable.init)?.arrayValue?.compactMap { $0 as? String } ?? []
            return kinds.contains("image") || kinds.contains("document")
        }.count
        let format = root["format"] as? String ?? "unknown"
        let completeFormats = [
            "tron.model_provider_request.v3",
            "tron.model_provider_request.v4",
        ]

        return SessionContextRequestSummaryDTO(
            eventId: eventId,
            sequence: sequence,
            timestamp: timestamp,
            format: format,
            turn: nonnegativeUInt64(root["turn"]),
            providerType: root["providerType"] as? String,
            providerName: root["providerName"] as? String,
            model: root["model"] as? String,
            requestClassification: root["requestClassification"] as? String ?? "legacy",
            messageCount: nonnegativeUInt64(root["messageCount"])
                ?? UInt64(messages.count),
            toolCount: nonnegativeUInt64(root["toolCount"]) ?? 0,
            automaticContextCount: UInt64(automaticContext.count),
            instructionCount: UInt64(systemContributions.count + providerAdditions.count),
            attachmentMessageCount: UInt64(attachmentCount),
            agentDeliveryCount: UInt64(agentDeliveries.count),
            environmentAvailable: manifest?["environment"]
                .map(AnyCodable.init)?.dictionaryValue?["workingDirectory"]
                .map { !AnyCodable($0).isNull } ?? false,
            manifestAvailable: manifestValue?.isNull == false,
            provenanceAvailability: completeFormats.contains(format)
                ? "complete"
                : "legacy_unavailable"
        )
    }

    func decodeDetail() async -> SessionContextRequestDetailDTO {
        await Task.detached(priority: .userInitiated) {
            let root = payload.dictionaryValue ?? [:]
            let manifest = root["contextManifest"].flatMap { value in
                try? JSONDecoder().decode(
                    SessionContextManifestDTO.self,
                    from: JSONEncoder().encode(AnyCodable(value))
                )
            }
            let providerAdditions = root["providerAdditions"].flatMap { value in
                try? JSONDecoder().decode(
                    [ContextSystemContributionDTO].self,
                    from: JSONEncoder().encode(AnyCodable(value))
                )
            }
            let format = root["format"] as? String ?? "unknown"
            return SessionContextRequestDetailDTO(
                eventId: eventId,
                sequence: sequence,
                timestamp: timestamp,
                format: format,
                contextManifest: manifest,
                providerAdditions: providerAdditions,
                providerAudit: payload,
                provenanceAvailability: [
                    "tron.model_provider_request.v3",
                    "tron.model_provider_request.v4",
                ].contains(format)
                    ? "complete"
                    : "legacy_unavailable"
            )
        }.value
    }

    private func nonnegativeUInt64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            value
        case let value as Int where value >= 0:
            UInt64(value)
        case let value as Double where value >= 0:
            UInt64(exactly: value.rounded(.towardZero))
        default:
            nil
        }
    }
}

extension SessionContextSheet {
    func observeSessionContext() async {
        refreshCoordinator.reset()
        defer { refreshCoordinator.reset() }
        let cachedEvent = loadCachedContextOverview()
        guard isConnected else {
            await loadCachedContextDetail(from: cachedEvent)
            return
        }

        requestAllSessionContextRefreshes()
        await loadCachedContextDetail(from: cachedEvent)

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
                requestLiveSessionStateRefreshes()
            } else if wasActive {
                requestLiveSessionStateRefreshes()
                requestProviderContextRefresh()
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

    func requestLiveSessionStateRefreshes() {
        guard isConnected else { return }
        requestWorkerRefresh()
        requestAgentUpdatesRefresh()
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
                latestContextDetail = nil
            }
            latestContextSummary = refreshedSummary
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

    @discardableResult
    func loadCachedContextOverview() -> CachedSessionContextEvent? {
        guard let event = cachedProviderRequestEvents.max(by: { $0.sequence < $1.sequence }) else {
            return nil
        }
        let cachedEvent = CachedSessionContextEvent(event)
        latestContextSummary = cachedEvent.summary
        contextLoadError = nil
        return cachedEvent
    }

    func loadCachedContextDetail(from event: CachedSessionContextEvent?) async {
        guard let event else { return }
        let detail = await event.decodeDetail()
        guard !Task.isCancelled,
              latestContextSummary?.eventId == detail.eventId else { return }
        latestContextDetail = detail
    }

    func openContextDetail(_ destination: SessionContextDetailDestination) {
        guard let summary = latestContextSummary else { return }
        if let detail = latestContextDetail, detail.eventId == summary.eventId {
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
                    eventId: summary.eventId
                )
                guard !Task.isCancelled,
                      contextDetailLoadingGeneration == generation,
                      latestContextSummary?.eventId == detail.eventId else { return }
                latestContextDetail = detail
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
        let manifest = detail.contextManifest
        switch destination {
        case .instructions:
            return .instructions(
                (manifest?.systemContributions ?? []) + (detail.providerAdditions ?? [])
            )
        case .messages:
            return .messages(manifest?.messages ?? [])
        case .deliveries:
            return .deliveries(manifest?.agentDeliveries ?? [])
        case .attachments:
            return .attachments(
                manifest?.messages.filter {
                    $0.contentKinds.contains("image")
                        || $0.contentKinds.contains("document")
                } ?? []
            )
        case .environment:
            return .environment(manifest?.environment)
        case .tools:
            return .tools(
                fixed: SessionContextPresentation.fixedToolSelections(
                    from: manifest?.toolSurface
                ),
                workers: SessionContextPresentation.workerSelections(
                    from: manifest?.toolSurface
                ),
                raw: manifest?.toolSurface
            )
        case .automaticContext:
            return .automatic(manifest?.automaticContext ?? [])
        case .providerAudit:
            return .providerAudit(
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

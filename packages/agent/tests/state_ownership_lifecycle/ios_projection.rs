use super::support::*;

fn contains_direct_user_defaults_standard(source: &str) -> bool {
    let without_swift_whitespace: String = source
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect();
    without_swift_whitespace.contains("UserDefaults.standard")
}

#[test]
fn direct_user_defaults_standard_detector_rejects_whitespace_variation() {
    let direct_standard_access = "UserDefaults . standard.removeObject(forKey: storageKey)";

    assert!(
        contains_direct_user_defaults_standard(direct_standard_access),
        "direct UserDefaults.standard access must be detected after normalizing Swift whitespace"
    );
}

#[test]
fn sol_ios_projection_local_state_lifecycle_is_source_backed() {
    let architecture = read_repo_file("packages/ios-app/docs/architecture.md");
    for required in [
        "## State Ownership",
        "The iOS app owns no canonical server truth.",
        "`EventDatabase` is a Documents-backed SQLite projection cache",
        "startup fails at the composition",
        "boundary instead of silently changing the projection substrate",
        "diagnostics harnesses may create explicit isolated database paths",
        "`EventStoreManager` owns the client generation for each persistence operation",
        "one strongly captured client into every page of that operation",
        "The two types rebuild local session/event",
        "projections from server session lists and event-sync APIs",
        "Engine stream cursors are stored per server",
        "origin/topic/filter for ACK coalescing and diagnostics only",
        "Server settings shown in the iOS settings UI are snapshots from",
        "Pairing is device-local `UserDefaults` state",
        "bearer tokens are per-server",
        "Keychain secrets",
        "MetricKit payloads are bounded Application Support diagnostics buffers",
    ] {
        assert!(
            architecture.contains(required),
            "iOS architecture state ownership docs missing `{required}`"
        );
    }

    let event_database =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift");
    for required in [
        "urls(for: .documentDirectory",
        ".appendingPathComponent(\".tron\", isDirectory: true)",
        ".appendingPathComponent(\"database\", isDirectory: true)",
        ".appendingPathComponent(\"prod.db\")",
        "init(databasePath: String)",
        "func clearAll() async throws",
        "DELETE FROM events",
        "DELETE FROM sessions",
        "DELETE FROM sync_state",
        "DELETE FROM session_drafts",
    ] {
        assert!(
            event_database.contains(required),
            "EventDatabase projection lifecycle missing `{required}`"
        );
    }
    for forbidden in [
        "EventDatabaseStorageMode",
        "temporaryCache",
        "temporaryCachePath",
        "NSTemporaryDirectory() + \".tron/database/events.db\"",
    ] {
        assert!(
            !event_database.contains(forbidden),
            "EventDatabase must not retain alternate production substrate marker `{forbidden}`"
        );
    }

    let dependency_storage = read_repo_file(
        "packages/ios-app/Sources/Support/Composition/DependencyContainerStorage.swift",
    );
    for required in [
        "static func production(",
        "defaults: () -> UserDefaults = { .standard }",
        "FileManager.default.urls(for: .documentDirectory",
        "eventDatabase: () -> EventDatabase? = { EventDatabase() }",
        "preconditionFailure(\"Documents directory unavailable; cannot initialize iOS local projection stores\")",
        "preconditionFailure(\"Documents directory unavailable; cannot initialize EventDatabase\")",
    ] {
        assert!(
            dependency_storage.contains(required),
            "DependencyContainerStorage iOS state lifecycle missing `{required}`"
        );
    }

    let dependency_container =
        read_repo_file("packages/ios-app/Sources/Support/Composition/DependencyContainer.swift");
    for required in [
        "storage: DependencyContainerStorage = .production(),",
        "runtimeIO: DependencyContainerRuntimeIO = .production()",
        "pairedServerTokenStore = runtimeIO.pairedServerTokenStore",
        "sessionAttemptDirective: runtimeIO.sessionAttemptDirective",
        "let db = storage.eventDatabase",
        "eventStoreManager.draftStore = draftStore",
        "selectPairedServer",
        "eventStoreManager.updateEngineClient(newClient)",
        "eventStoreManager.attachConnectionManager(manager)",
    ] {
        assert!(
            dependency_container.contains(required),
            "DependencyContainer iOS state lifecycle missing `{required}`"
        );
    }
    for forbidden in [
        "EventDatabase(temporaryCachePath:",
        "eventDatabaseStorageMode",
        "NSTemporaryDirectory()",
    ] {
        assert!(
            !dependency_container.contains(forbidden) && !dependency_storage.contains(forbidden),
            "iOS composition owners must not retain alternate production state path `{forbidden}`"
        );
    }

    let event_store_manager =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift");
    for required in [
        "let predecessor = globalEventTask",
        "predecessor?.cancel()",
        "await predecessor?.value",
        "for await event in stream",
        "guard let self else { return }",
        "await self.acceptedEventHook(event)",
        "await self.handleGlobalEventV2(event)",
        "func shutdown() async",
        "await globalTask?.value",
        "await refreshCoordinator.shutdown()",
        "await loadTask?.value",
        "engineClient = client",
        "setupGlobalEventHandlers()",
        "private var processingOverrides:",
        "withTaskCancellationHandler",
        "authoritativeProcessingSessionIds?.contains(sessionId)",
        "override.revision > $0",
    ] {
        assert!(
            event_store_manager.contains(required),
            "EventStoreManager task/projection lifecycle missing `{required}`"
        );
    }

    let event_store_sync = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager+Sync.swift",
    );
    assert_contains_in_order(
        "iOS session list projection refresh",
        &event_store_sync,
        &[
            "fetchServerSessions",
            "serverSessionIds",
            "eventDB.sessions.getAll()",
            "authoritativeProcessingSessionIds.insert(sessionId)",
            "mergeSessionData",
            "serverSessionToCached",
            "reconcileServerSnapshot",
            "loadSessionsAfterRefresh(",
            "authoritativeProcessingSessionIds: authoritativeProcessingSessionIds",
        ],
    );
    let event_store_activity = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager+SessionActivity.swift",
    );
    for forbidden in ["processingSessionIds", "seedProcessingStateFromSessions"] {
        assert!(
            !event_store_manager.contains(forbidden)
                && !event_store_sync.contains(forbidden)
                && !event_store_activity.contains(forbidden),
            "EventStoreManager must not retain duplicate processing projection `{forbidden}`"
        );
    }
    for required in [
        "max(existing.eventCount, serverInfo.eventCount ?? existing.eventCount)",
        "session.rootEventId = existing.rootEventId",
        "session.headEventId = existing.headEventId",
        "session.serverOrigin = serverOrigin",
        "existingOrigin != serverOrigin",
    ] {
        assert!(
            event_store_sync.contains(required),
            "EventStoreManager projection merge missing `{required}`"
        );
    }

    let synchronizer = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/SessionSynchronizer.swift",
    );
    assert_contains_in_order(
        "iOS event sync cursor projection",
        &synchronizer,
        &[
            "eventDB.sync.getState(sessionId)",
            "lastSyncedEventId",
            "operationClient.eventSync.getSince",
            "eventDB.events.insertBatch(events)",
            "eventDB.sync.update(newSyncState)",
        ],
    );
    for required in [
        "fullSync(sessionId: String, using operationClient: EngineClient)",
        "eventDB.events.deleteBySession(sessionId)",
        "lastSyncedEventId: nil",
        "operationClient.eventSync.getAll(sessionId: sessionId)",
        "fetchMissingAncestors",
        "operationClient.eventSync.getAncestors(parentId)",
        "insertIgnoringDuplicates",
    ] {
        assert!(
            synchronizer.contains(required),
            "SessionSynchronizer lifecycle missing `{required}`"
        );
    }

    let cursor_store = read_repo_file(
        "packages/ios-app/Sources/Engine/Persistence/Sync/EngineStreamCursorStore.swift",
    );
    for required in [
        "serverOrigin: String",
        "filterHash: String",
        "Session history is never restored from this store",
        "save(_ cursor: EngineStreamCursor",
        "guard existing.map({ cursor > $0 }) ?? true else { return }",
        "removeAll()",
    ] {
        assert!(
            cursor_store.contains(required),
            "Engine stream cursor lifecycle missing `{required}`"
        );
    }

    let engine_client =
        read_repo_file("packages/ios-app/Sources/Engine/Transport/WebSocket/EngineClient.swift");
    for required in [
        "Session history is reconstructed through `session::reconstruct`.",
        "sessionEventSubscriptionCursor(stored: EngineStreamCursor?) -> EngineStreamCursor?",
        "nil",
        "clearActiveStreamSubscriptions(reason: \"explicit disconnect\")",
        "streamCursorStore.save(cursor, for: key)",
        "scheduleStreamAck(subscriptionId: subscriptionId, cursor: cursor)",
        "streamAckCoalescer.removeAll()",
        "streamSubscriptions.removeAll()",
        "streamSubscriptionKeysById.removeAll()",
    ] {
        assert!(
            engine_client.contains(required),
            "EngineClient stream projection lifecycle missing `{required}`"
        );
    }

    let engine_connection = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection.swift",
    );
    for required in [
        "reconnectTask?.cancel()",
        "openTimeoutTask?.cancel()",
        "pingTask?.cancel()",
        "receiveTask?.cancel()",
        "failPendingRequests(error:",
        "setBackgroundState",
        "Cancelling in-flight reconnect for background transition",
        "cleanupDeadConnection",
    ] {
        assert!(
            engine_connection.contains(required),
            "EngineConnection lifecycle missing `{required}`"
        );
    }
    let engine_receiving = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection+Receiving.swift",
    );
    for required in [
        "timeoutTasks.values.forEach { $0.cancel() }",
        "pendingRequests.removeAll()",
        "timeoutTasks.removeAll()",
    ] {
        assert!(
            engine_receiving.contains(required),
            "EngineConnection request cleanup missing `{required}`"
        );
    }
    let connection_manager =
        read_repo_file("packages/ios-app/Sources/Engine/Transport/Retry/ConnectionManager.swift");
    for required in [
        "deinit",
        "observationTask?.cancel()",
        "hooks.removeAll()",
        "runOnReconnect",
        "cancelHook(label: String)",
    ] {
        assert!(
            connection_manager.contains(required),
            "ConnectionManager hook lifecycle missing `{required}`"
        );
    }

    let settings_state =
        read_repo_file("packages/ios-app/Sources/Session/Chat/State/SettingsState.swift");
    for required in [
        "Observable state for server-authoritative settings",
        "settingsRepository.get()",
        "settingsRepository.resetToDefaults",
        "clearServerSnapshot()",
        "rollbackToLastLoadedSettings",
        "applyServerSettings",
        "lastLoadedSettings = settings",
        "Every field is overwritten from the active server's effective settings.",
    ] {
        assert!(
            settings_state.contains(required),
            "SettingsState server snapshot lifecycle missing `{required}`"
        );
    }

    let paired_store =
        read_repo_file("packages/ios-app/Sources/Support/Pairing/PairedServerStore.swift");
    for required in [
        "iOS-local source of truth for paired servers and active selection.",
        "fresh store starts empty",
        "serversKey",
        "activeIdKey",
        "normalizeActiveSelection()",
        "func replace(",
        "func select(",
        "func remove(",
        "shouldReturnToOnboarding: servers.isEmpty",
    ] {
        assert!(
            paired_store.contains(required),
            "PairedServerStore local lifecycle missing `{required}`"
        );
    }

    let token_store =
        read_repo_file("packages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift");
    for required in [
        "Per-paired-server bearer-token registry",
        "Keychain",
        "keychainServicePrefix",
        "func setToken",
        "func token(forServerId",
        "func remove(serverId",
        "static let production = Backend(",
        "try makeProductionItem(for: id).set(token)",
        "makeProductionItem(for: id).get()",
        "try makeProductionItem(for: id).delete()",
        "account: id",
    ] {
        assert!(
            token_store.contains(required),
            "PairedServerTokenStore secret lifecycle missing `{required}`"
        );
    }

    let draft_store = read_repo_file("packages/ios-app/Sources/Support/Storage/DraftStore.swift");
    for required in [
        "debounceTask?.cancel()",
        "pendingSessionId",
        "pendingInputBarState",
        "flushPending()",
        "clearDraft(sessionId:",
        "deleteSessionDraft(sessionId:",
        "removeAttachmentFiles(sessionId:",
        "removeAllDraftFiles()",
    ] {
        assert!(
            draft_store.contains(required),
            "DraftStore local workflow lifecycle missing `{required}`"
        );
    }
    let history_store =
        read_repo_file("packages/ios-app/Sources/Support/Storage/InputHistoryStore.swift");
    for required in [
        "storageKey = \"tron.inputHistory\"",
        "maxHistorySize = 100",
        "private let defaults: UserDefaults",
        "init(defaults: UserDefaults)",
        "self.defaults = defaults",
        "defaults.data(forKey: storageKey)",
        "defaults.set(data, forKey: storageKey)",
        "defaults.removeObject(forKey: storageKey)",
        "history = Array(history.prefix(maxHistorySize))",
        "resetNavigation()",
        "clearHistory()",
    ] {
        assert!(
            history_store.contains(required),
            "InputHistoryStore local lifecycle missing `{required}`"
        );
    }
    assert!(
        !contains_direct_user_defaults_standard(&history_store),
        "InputHistoryStore must require its defaults owner, not reach for UserDefaults.standard"
    );

    let shared_content =
        read_repo_file("packages/ios-app/Sources/Support/Share/SharedContent.swift");
    for required in [
        "App Group UserDefaults",
        "static let suiteName",
        "static func save",
        "static func load",
        "static func clear",
        "suite.removeObject(forKey: key)",
    ] {
        assert!(
            shared_content.contains(required),
            "PendingShareService handoff lifecycle missing `{required}`"
        );
    }

    let metric_store = read_repo_file(
        "packages/ios-app/Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
    );
    for required in [
        "applicationSupportDirectory",
        "MetricKitDiagnostics",
        "preconditionFailure(\"Application Support directory unavailable",
        "private let lock = NSLock()",
        "maxAgeDays",
        "maxFiles",
        "maxTotalBytes",
        "try encoded.write(to: url, options: [.atomic])",
        "pruneStoredPayloadsLocked",
        "fileManager.removeItem",
        "loadPayloads(maxFiles: Int = 50, maxBytes: Int = 1_000_000)",
    ] {
        assert!(
            metric_store.contains(required),
            "MetricKitDiagnosticsStore buffer lifecycle missing `{required}`"
        );
    }
    assert!(
        !metric_store.contains("NSTemporaryDirectory()"),
        "MetricKit diagnostics must not silently move to temporary storage"
    );

    let diagnostics_builder = read_repo_file(
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
    );
    assert!(
        !diagnostics_builder.contains("eventDatabaseStorageMode")
            && !diagnostics_builder.contains("storageMode"),
        "Diagnostics bundle must not report deleted event database storage modes"
    );
}

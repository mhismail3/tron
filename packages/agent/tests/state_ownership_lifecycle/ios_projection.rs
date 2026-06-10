use super::support::*;

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
        "`EventStoreManager` and `SessionSynchronizer` rebuild local session/event",
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

    let dependency_container =
        read_repo_file("packages/ios-app/Sources/Support/Composition/DependencyContainer.swift");
    for required in [
        "preconditionFailure(\"Documents directory unavailable; cannot initialize iOS local projection stores\")",
        "preconditionFailure(\"Documents directory unavailable; cannot initialize EventDatabase\")",
        "let db = EventDatabase()",
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
            !dependency_container.contains(forbidden),
            "DependencyContainer must not retain alternate production state path `{forbidden}`"
        );
    }

    let event_store_manager =
        read_repo_file("packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift");
    for required in [
        "globalEventTask?.cancel()",
        "globalEventTask = Task",
        "sessionSynchronizer.updateEngineClient(client)",
        "setupGlobalEventHandlers()",
        "handleSessionDeleted",
        "handleSessionArchived",
        "handleSessionUnarchived",
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
            "mergeSessionData",
            "serverSessionToCached",
            "getByOrigin(serverOrigin)",
            "deleteBySession(local.id)",
            "sessions.delete(local.id)",
            "loadSessions()",
            "seedProcessingStateFromSessions()",
        ],
    );
    for required in [
        "max(existing.eventCount, serverInfo.eventCount ?? existing.eventCount)",
        "session.rootEventId = existing.rootEventId",
        "session.headEventId = existing.headEventId",
        "session.serverOrigin = serverOrigin",
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
            "engineClient.eventSync.getSince",
            "eventDB.events.insertBatch(events)",
            "eventDB.sync.update(newSyncState)",
        ],
    );
    for required in [
        "fullSync(sessionId: String)",
        "eventDB.events.deleteBySession(sessionId)",
        "lastSyncedEventId: nil",
        "engineClient.eventSync.getAll(sessionId: sessionId)",
        "fetchMissingAncestors",
        "engineClient.eventSync.getAncestors(parentId)",
        "insertIgnoringDuplicates",
        "sessionHasDifferentOrigin",
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
        "There is intentionally no migration from the removed server-side pairing",
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
        "history = Array(history.prefix(maxHistorySize))",
        "resetNavigation()",
        "clearHistory()",
        "UserDefaults.standard.removeObject",
    ] {
        assert!(
            history_store.contains(required),
            "InputHistoryStore local lifecycle missing `{required}`"
        );
    }

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

    let inventory = inventory_by_path();
    for required in [
        "packages/ios-app/Sources/Engine/Persistence/SQLite/EventDatabase.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/EngineStreamCursorStore.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/EventStoreManager+Sync.swift",
        "packages/ios-app/Sources/Engine/Persistence/Sync/SessionSynchronizer.swift",
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineClient.swift",
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection.swift",
        "packages/ios-app/Sources/Engine/Transport/Retry/ConnectionManager.swift",
        "packages/ios-app/Sources/Session/Chat/State/SettingsState.swift",
        "packages/ios-app/Sources/Support/Composition/DependencyContainer.swift",
        "packages/ios-app/Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
        "packages/ios-app/Sources/Support/Pairing/PairedServerStore.swift",
        "packages/ios-app/Sources/Support/Share/SharedContent.swift",
        "packages/ios-app/Sources/Support/Storage/DraftStore.swift",
        "packages/ios-app/Sources/Support/Storage/InputHistoryStore.swift",
        "packages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift",
        "packages/ios-app/docs/architecture.md",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-8"))),
            "SOL inventory must tag {required} as part of SOL-8"
        );
    }
    assert!(
        inventory
            .iter()
            .filter(|(path, _)| path.starts_with("packages/ios-app/Sources/"))
            .all(|(_, rows)| rows.iter().all(|row| row.state_class != "canonical_truth")),
        "iOS source inventory rows must not claim canonical server truth"
    );
}

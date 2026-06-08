use super::support::*;

#[test]
fn retained_event_payload_surface_is_loop_owned() {
    let payloads =
        read_repo_file("packages/agent/src/domains/session/event_store/types/payloads/mod.rs");
    let generated =
        read_repo_file("packages/agent/src/domains/session/event_store/types/generated.rs");
    let pause_requested = ["Capability", "Pause", "Requested"].concat();
    let pause_resolved = ["Capability", "Pause", "Resolved"].concat();

    assert_absent(
        &payloads,
        &[
            "pub mod device;",
            "pub mod file;",
            "pub mod hook;",
            "pub mod memory;",
            "pub mod notification;",
            "pub mod repo;",
            "pub mod rules;",
            "pub mod skill;",
            "pub mod subagent;",
            "pub mod todo;",
            "pub mod worktree;",
        ],
        "typed payload module surface",
    );
    assert_absent(
        &generated,
        &[
            concat!("Message", "Queued"),
            concat!("Message", "Dequeued"),
            pause_requested.as_str(),
            pause_resolved.as_str(),
            "CapabilityRunStatus",
            "ConfigModelSwitch",
            "ConfigPromptUpdate",
            "ConfigReasoningLevel",
            "Notification",
            "Skill",
            "Rules",
            "File",
            "Worktree",
            "Subagent",
            "ProcessResults",
            "UserJob",
            "Todo",
            "Hook",
            "Memory",
            "Repo",
            "DeviceToken",
            "ServerUpdateAvailable",
            "is_worktree_type",
            "is_repo_type",
            "is_subagent_type",
            "is_hook_type",
            "is_skill_type",
            "is_rules_type",
            "is_queue_type",
            "is_file_type",
            "is_server_type",
        ],
        "generated event type surface",
    );
}

#[test]
fn diagnostics_logging_surface_is_flattened_to_execute_evidence() {
    assert_repo_path_absent(
        "packages/agent/src/shared/logging/store.rs",
        "unused generic log query abstraction",
    );

    let logging_mod = read_repo_file("packages/agent/src/shared/observability/mod.rs");
    let logging_types = read_repo_file("packages/agent/src/shared/observability/types.rs");
    for (source, label) in [
        (logging_mod.as_str(), "shared logging module"),
        (logging_types.as_str(), "shared logging types"),
    ] {
        assert_absent(
            source,
            &["LogStore", "LogEntry", "LogQueryOptions", "SortOrder"],
            label,
        );
    }

    let system_surface = read_repo_file("packages/agent/src/domains/system/mod.rs");
    assert_absent(
        &system_surface,
        &[
            "system::get_diagnostics",
            "get_diagnostics",
            "system_diagnostics_value",
        ],
        "system debug diagnostics surface",
    );

    let settings_surface = [
        read_repo_file("packages/agent/src/domains/settings/profile/types/server.rs"),
        read_repo_file("packages/agent/defaults/profiles/default/profile.toml"),
        read_repo_file(
            "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
        ),
        read_repo_file("packages/ios-app/Sources/Session/Chat/State/SettingsState.swift"),
        read_repo_file("packages/ios-app/Sources/UI/Settings/Pages/ConnectionSettingsPage.swift"),
        read_repo_file("README.md"),
    ]
    .join("\n");
    assert_absent(
        &settings_surface,
        &[
            "payloadCapture",
            "maxInlinePayloadBytes",
            "PayloadCapture",
            "observabilityPayloadCapture",
            "observabilityMaxInlinePayloadBytes",
            "Inline bytes",
        ],
        "retained observability settings surface",
    );

    let execute_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    let execute_ops = read_repo_source_trees(&["packages/agent/src/domains/capability/operations"]);
    let trace_proof = read_repo_file("packages/agent/tests/primitive_trace_execution.rs");
    for (source, label) in [
        (execute_contract.as_str(), "execute contract"),
        (execute_ops.as_str(), "execute operations"),
        (trace_proof.as_str(), "primitive trace/log proof"),
    ] {
        assert!(
            source.contains("log_recent"),
            "{label} must expose log evidence through the single execute primitive"
        );
    }

    let ios_surface = [
        read_repo_file("packages/ios-app/Sources/Engine/Transport/Clients/LogsClient.swift"),
        read_repo_file(
            "packages/ios-app/Sources/Engine/Protocol/System/EngineProtocolTypes+System.swift",
        ),
        read_repo_file("packages/ios-app/Sources/UI/Settings/Shell/SettingsSupport.swift"),
        read_repo_file("packages/ios-app/Sources/UI/Settings/Pages/ConnectionSettingsPage.swift"),
    ]
    .join("\n");
    assert_absent(
        &ios_surface,
        &[
            "SystemDiagnosticsResult",
            "getDiagnostics",
            "system::get_diagnostics",
            "ConnectionSettingsServerBackedSection",
            "diagnosticsSection",
        ],
        "retained iOS diagnostics settings surface",
    );
    assert!(
        ios_surface.contains("runtimeEvidenceSection"),
        "iOS settings should render the one retained evidence section directly"
    );
}

#[test]
fn dynamic_runtime_surfaces_are_schema_rendering_not_target_authoring() {
    assert_repo_path_absent(
        "packages/agent/src/engine/primitives/ui/authoring",
        "server-owned generated UI target authoring",
    );
    assert_repo_path_absent(
        "packages/agent/src/engine/primitives/action_summary.rs",
        "server-owned UI action summary projection",
    );
    assert_repo_path_absent(
        "packages/agent/src/engine/primitives/control/actions.rs",
        "server-owned UI control action projection",
    );

    let rust_surface = [
        read_repo_file("packages/agent/src/engine/primitives/ui/mod.rs"),
        read_repo_file("packages/agent/src/engine/primitives/ui/schemas.rs"),
        read_repo_file("packages/agent/src/engine/primitives/ui/validation.rs"),
        read_repo_file("packages/agent/src/engine/durability/resources/types.rs"),
        read_repo_file("packages/agent/src/engine/durability/resources/ui_surface.rs"),
    ]
    .join("\n");
    assert_absent(
        &rust_surface,
        &[
            "ui::catalog",
            "ui::surface_for_target",
            "ui::refresh_surface",
            "ui_component_catalog",
            "UI_CATALOG_ID",
            "UI_CATALOG_REVISION",
            "SurfaceAuthoringRequest",
            "author_surface_for_target",
            "targetFunctionId",
            "requiredGrant",
            "requiredRisk",
            "targetRevision",
            "payloadTemplate",
            "idempotencyKeyTemplate",
            "WorkerRef",
            "\"bindings\"",
            "\"authoring\"",
            "\"redactionPolicy\"",
            "\"refreshPolicy\"",
        ],
        "retained Rust dynamic surface primitive",
    );

    let ios_surface = [
        read_repo_file(
            "packages/ios-app/Sources/Engine/Protocol/GeneratedUI/EngineProtocolTypes+GeneratedUI.swift",
        ),
        read_repo_file(
            "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
        ),
        read_repo_file("packages/ios-app/Tests/Engine/Protocol/GeneratedUIDTOTests.swift"),
        read_repo_file("packages/ios-app/Tests/UI/RuntimeSurfaces/GeneratedUIRendererTests.swift"),
    ]
    .join("\n");
    assert_absent(
        &ios_surface,
        &[
            "UiCatalog",
            "catalogId",
            "catalogRevision",
            "targetFunctionId",
            "requiredGrant",
            "requiredRisk",
            "targetRevision",
            "payloadTemplate",
            "idempotencyKeyTemplate",
            "UiBindingDTO",
            "UiSurfaceAuthoringDTO",
            "UiSurfaceForTargetRequestDTO",
            "UiSurfaceRefreshRequestDTO",
            "WorkerRef",
            "workerId",
            "bindings",
            "authoring",
            "redactionPolicy",
            "refreshPolicy",
        ],
        "retained iOS dynamic runtime surface",
    );
    assert!(
        ios_surface.contains("schemaVersion"),
        "dynamic runtime surfaces should keep one explicit schema version primitive"
    );
}

#[test]
fn queue_trigger_and_prompt_envelopes_do_not_pin_preexecution_catalog_state() {
    let retained_envelope = [
        read_repo_file("packages/agent/src/engine/durability/queue/mod.rs"),
        read_repo_file("packages/agent/src/engine/durability/queue/runtime.rs"),
        read_repo_file("packages/agent/src/engine/durability/queue/sqlite_codec.rs"),
        read_repo_file("packages/agent/src/engine/primitives/queue.rs"),
        read_repo_file("packages/agent/src/engine/runtime/triggers.rs"),
        read_repo_file("packages/agent/src/engine/primitives/trigger.rs"),
        read_repo_file("packages/agent/src/engine/kernel/types/mod.rs"),
        read_repo_file("packages/agent/src/engine/kernel/policy.rs"),
        read_repo_file("packages/agent/src/domains/agent/prompt/prompt.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/deps.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/events.rs"),
        read_repo_file("packages/agent/src/domains/agent/runtime/service/execute.rs"),
        read_repo_file("packages/agent/src/domains/agent/stream.rs"),
    ]
    .join("\n");
    assert_absent(
        &retained_envelope,
        &[
            "targetRevision",
            "target_revision",
            "expectedFunctionRevision",
            "expected_function_revision",
            "targetFunctionId",
            "catalogRevision",
        ],
        "retained queue/trigger/prompt runtime envelope",
    );
}

#[test]
fn engine_invocation_and_transport_do_not_require_expected_revision_tokens() {
    let retained_invocation_surface = [
        read_repo_file("README.md"),
        read_repo_file("packages/agent/src/engine/invocation/host/mod.rs"),
        read_repo_file("packages/agent/src/engine/invocation/host/meta.rs"),
        read_repo_file("packages/agent/src/engine/invocation/model.rs"),
        read_repo_file("packages/agent/src/engine/catalog/registry/invocation.rs"),
        read_repo_file("packages/agent/src/engine/runtime/worker_protocol.rs"),
        read_repo_file("packages/agent/src/engine/runtime/external_workers/mod.rs"),
        read_repo_file("packages/agent/src/engine/durability/ledger/outcome.rs"),
        read_repo_file("packages/agent/src/engine/kernel/errors.rs"),
        read_repo_file("packages/agent/src/transport/engine/socket/mod.rs"),
        read_repo_file("packages/agent/src/transport/engine/socket/wire.rs"),
        read_repo_file("packages/agent/src/transport/engine/contracts.rs"),
        read_repo_file("packages/agent/src/engine/tests/invocation/host_invocation.rs"),
        read_repo_file("packages/agent/src/engine/tests/invocation/meta_primitives.rs"),
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker.rs"),
        read_repo_file("packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift"),
        read_repo_file("packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection.swift"),
        read_repo_file(
            "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnectionProtocolFrames.swift",
        ),
    ]
    .join("\n");
    assert_absent(
        &retained_invocation_surface,
        &[
            "expectedFunctionRevision",
            "expected_function_revision",
            "expectedRevision",
            "expected_revision",
            "expecting_revision",
            "StaleFunctionRevision",
            "stale_function_revision",
        ],
        "retained engine invocation/transport surface",
    );
}

#[test]
fn control_projection_primitive_is_deleted() {
    let retained_control_surface = [
        read_repo_file("packages/agent/src/engine/primitives/mod.rs"),
        read_repo_file("packages/agent/src/engine/primitives/runtime.rs"),
        read_repo_file("packages/ios-app/project.yml"),
    ]
    .join("\n");
    assert_absent(
        &retained_control_surface,
        &[
            "CONTROL_WORKER_ID",
            "control::",
            "mod control",
            "ControlSnapshotDTO",
        ],
        "retained control projection registration surface",
    );
    assert!(
        !repo_path("packages/agent/src/engine/primitives/control.rs").exists(),
        "control primitive source should be deleted"
    );
    assert!(
        !repo_path(
            "packages/ios-app/Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Control.swift"
        )
        .exists(),
        "iOS control DTO should be deleted"
    );
}

#[test]
fn public_catalog_readout_state_is_not_client_envelope_state() {
    let transport_surface = [
        read_repo_file("packages/agent/src/transport/engine/contracts.rs"),
        read_repo_file("packages/agent/src/transport/engine/socket/mod.rs"),
        read_repo_file(
            "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnectionProtocolFrames.swift",
        ),
    ]
    .join("\n");
    assert_absent(
        &transport_surface,
        &[
            "currentCatalogRevision",
            "\"catalogRevision\": catalog_revision",
            "let catalogRevision: UInt64?",
            "let currentCatalogRevision",
        ],
        "public engine transport envelope catalog readout surface",
    );
    let swift_protocol =
        read_repo_file("packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift");
    let response_frame = swift_protocol
        .split("struct EngineProtocolResponseFrame")
        .nth(1)
        .and_then(|tail| tail.split("struct EngineFunctionCallEnvelope").next())
        .expect("EngineProtocolResponseFrame section should exist");
    assert_absent(
        response_frame,
        &["catalogRevision"],
        "iOS top-level response frame",
    );
    let function_call_envelope = swift_protocol
        .split("struct EngineFunctionCallEnvelope")
        .nth(1)
        .and_then(|tail| tail.split("struct EngineChildInvocation").next())
        .expect("EngineFunctionCallEnvelope section should exist");
    assert_absent(
        function_call_envelope,
        &["catalogRevision"],
        "iOS function-call envelope",
    );

    let public_catalog_read_surface = [
        read_repo_file("packages/agent/src/engine/invocation/host/mod.rs"),
        read_repo_file("packages/agent/src/engine/invocation/host/meta.rs"),
        read_repo_file("packages/agent/src/engine/primitives/catalog.rs"),
        read_repo_file("packages/agent/src/engine/primitives/runtime.rs"),
        read_repo_file("packages/agent/src/engine/primitives/worker.rs"),
    ]
    .join("\n");
    assert_absent(
        &public_catalog_read_surface,
        &[
            "\"catalogRevision\": self.catalog.revision().0",
            "\"catalogRevision\": host.catalog_revision().0",
            "\"catalogRevision\": catalog_revision.0",
            "\"required\": [\"catalogRevision\"",
            "\"catalogRevision\": {\"type\": \"integer\"}",
        ],
        "public catalog/meta/worker readout catalog revision surface",
    );
}

#[test]
fn prompt_suggestion_lifecycle_state_is_deleted_from_retained_sources() {
    let retained_sources = read_repo_source_trees(&[
        "packages/agent/src",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/ios-app/project.yml",
    ]);
    let forbidden = [
        ["post", "Processing"].concat(),
        ["is", "Post", "Processing"].concat(),
        ["post", "-", "processing"].concat(),
        ["post", " processing"].concat(),
        ["awaiting", "Suggestions"].concat(),
        ["suggest", "-", "prompts"].concat(),
        ["Pull", "Up", "Panel"].concat(),
        ["Llm", "Hook", "Result"].concat(),
        ["hook", ".", "llm", "_", "result"].concat(),
    ];
    for token in forbidden {
        assert!(
            !retained_sources.contains(&token),
            "retained primitive sources must not contain deleted prompt-suggestion lifecycle token `{token}`"
        );
    }
}

#[test]
fn user_interaction_pause_plane_is_deleted_from_retained_sources() {
    let retained_sources = read_repo_source_trees(&[
        "packages/agent/src",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/ios-app/project.yml",
    ]);
    let forbidden = [
        ["User", "Interaction", "Invocation"].concat(),
        ["User", "Interaction", "Capability"].concat(),
        ["User", "Interaction", "Coordinator"].concat(),
        ["User", "Interaction", "State"].concat(),
        ["User", "Interaction", "Sheet"].concat(),
        ["User", "Interaction", "Viewer"].concat(),
        ["answered", "Questions"].concat(),
        ["submit", "Answers"].concat(),
        ["Submit", "Answers"].concat(),
        ["Answer", "Submission"].concat(),
        ["agent::", "submit", "_", "answers"].concat(),
        ["capability", ".", "pause", "."].concat(),
        ["Capability", "Pause"].concat(),
        ["pause", "Id"].concat(),
        ["prompt", "Payload"].concat(),
        ["answer", "Authority"].concat(),
        ["resume", "Schema"].concat(),
        ["interaction", "Status"].concat(),
        ["parsed", "Answers"].concat(),
        ["ask", "_", "user"].concat(),
        ["mark", "Pending", "Questions", "As", "Superseded"].concat(),
    ];
    for token in forbidden {
        assert!(
            !retained_sources.contains(&token),
            "retained primitive sources must not contain deleted user-interaction pause-plane token `{token}`"
        );
    }
}

use super::support::*;

#[test]
fn prompt_media_uses_unified_attachment_primitive() {
    let rust_files = [
        "packages/agent/src/domains/agent/contract.rs",
        "packages/agent/src/domains/agent/prompt/prompt.rs",
        "packages/agent/src/domains/agent/runtime/service/request.rs",
        "packages/agent/src/domains/agent/runtime/service/execute.rs",
        "packages/agent/src/domains/agent/runtime/runtime/user_event.rs",
    ];
    for path in rust_files {
        let source = read_repo_file(path);
        assert!(
            source.contains("attachments") || source.contains("FileAttachment"),
            "{path} must keep the unified prompt attachment primitive"
        );
        assert_absent(
            &source,
            &[
                "\"images\"",
                "opt_array(params, \"images\")",
                "validate_attachment_arrays",
                "pub images",
                "images.as_deref()",
                "mediaType",
            ],
            path,
        );
    }

    let ios_files = [
        "packages/ios-app/Sources/Engine/Protocol/Agent/EngineProtocolTypes+Agent.swift",
        "packages/ios-app/Sources/Engine/Transport/Clients/AgentClient.swift",
        "packages/ios-app/Sources/Engine/Transport/Clients/AgentClientProtocol.swift",
        "packages/ios-app/Sources/Engine/Transport/Clients/Repositories/Defaults/Protocols/AgentRepository.swift",
        "packages/ios-app/Sources/Engine/Transport/Clients/Repositories/Defaults/DefaultAgentRepository.swift",
        "packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel+Messaging.swift",
        "packages/ios-app/Tests/Engine/Transport/Clients/AgentClientTests.swift",
        "packages/ios-app/Tests/Engine/Transport/Clients/Repositories/DefaultAgentRepositoryTests.swift",
        "packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesTests.swift",
    ];
    for path in ios_files {
        let source = read_repo_file(path);
        assert!(
            source.contains("attachments") || source.contains("FileAttachment"),
            "{path} must keep the unified prompt attachment primitive"
        );
        assert_absent(
            &source,
            &[
                "ImageAttachment",
                "lastImages",
                "lastSendPromptImages",
                "images:",
                "\"images\"",
            ],
            path,
        );
    }
}

#[test]
fn ios_shell_has_no_fixed_session_tree_projection() {
    for (path, label) in [
        (
            "packages/ios-app/Sources/UI/SessionTree",
            "fixed iOS session-tree view root",
        ),
        (
            "packages/ios-app/Sources/Engine/Database/Repositories/TreeRepository.swift",
            "fixed local event-tree repository",
        ),
        (
            "packages/ios-app/Sources/Engine/EventStore/EventTreeBuilder.swift",
            "fixed local event-tree projection builder",
        ),
        (
            "packages/ios-app/Tests/Infrastructure/TreeRepositoryTests.swift",
            "fixed local event-tree repository tests",
        ),
        (
            "packages/ios-app/Tests/Views/ForkButtonTests.swift",
            "fixed fork-row tests",
        ),
        (
            "packages/ios-app/Tests/Views/EventIconProviderTests.swift",
            "fixed session-tree icon provider tests",
        ),
    ] {
        assert_repo_path_absent(path, label);
    }

    let retained_ios = read_repo_source_trees(&[
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/ios-app/project.yml",
    ]);
    assert_absent(
        &retained_ios,
        &[
            "EventTreeNode",
            "EventTreeBuilder",
            "TreeRepository",
            "ForkPointIndicator",
            "ForkButtonState",
            "EventIconProvider",
            "getTreeVisualization",
            "database.tree",
            "eventDB.tree",
            "isBranchPoint",
        ],
        "retained iOS session-tree projection surface",
    );
}

#[test]
fn approval_and_observability_planes_are_not_engine_primitives() {
    for (path, label) in [
        (
            "packages/agent/src/engine/approval.rs",
            "engine approval record/store module",
        ),
        (
            "packages/agent/src/engine/approval",
            "engine approval store support directory",
        ),
        (
            "packages/agent/src/engine/primitives/approval.rs",
            "approval primitive worker",
        ),
        (
            "packages/agent/src/engine/primitives/observability.rs",
            "observability primitive worker",
        ),
        (
            "packages/agent/src/engine/tests/approval.rs",
            "approval primitive tests",
        ),
        (
            "packages/agent/src/engine/tests/approval_autonomy.rs",
            "approval autonomy tests",
        ),
        (
            "packages/agent/src/engine/tests/trace_observability.rs",
            "old observability trace tests",
        ),
    ] {
        assert_repo_path_absent(path, label);
    }

    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    assert_absent(
        &engine_mod,
        &[
            "pub mod approval;",
            "pub use approval",
            "EngineApprovalRecord",
            "EngineApprovalRequest",
            "SqliteEngineApprovalStore",
        ],
        "engine root exports",
    );

    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    assert_absent(
        &primitives,
        &[
            "mod approval;",
            "mod observability;",
            "APPROVAL_WORKER_ID",
            "OBSERVABILITY_WORKER_ID",
            "APPROVAL_REQUEST_FUNCTION",
            "APPROVAL_RESOLVE_FUNCTION",
            "approval::registrations",
            "observability::registrations",
            "ApprovalStoreBackend",
            "parse_approval_status",
        ],
        "engine primitive registrations",
    );

    let capability_client = read_repo_file("packages/agent/src/engine/catalog/capabilities.rs");
    assert_absent(
        &capability_client,
        &[
            "AutonomyApprovalPromptMode",
            "EngineApprovalRequest",
            "EngineApprovalTargetMetadata",
            "approval_required",
            "request_approval",
            "auto_approve_and_invoke",
            "approval primitives are owned",
        ],
        "agent capability client",
    );

    let host = read_repo_file("packages/agent/src/engine/invocation/host/mod.rs");
    assert_absent(
        &host,
        &[
            "EngineApprovalRecord",
            "EngineApprovalRequest",
            "EngineApprovalTargetMetadata",
            "EngineAutoApprovalOutcome",
            "APPROVAL_REQUEST_FUNCTION",
            "APPROVAL_RESOLVE_FUNCTION",
        ],
        "engine host root",
    );

    for (path, label) in [
        (
            "packages/agent/src/engine/invocation/host/invocation_handle.rs",
            "engine host invocation path",
        ),
        (
            "packages/agent/src/engine/invocation/host/substrate_handle.rs",
            "engine host substrate methods",
        ),
        (
            "packages/agent/src/engine/primitives/runtime.rs",
            "engine primitive runtime",
        ),
        (
            "packages/agent/src/domains/session/reconstruction/mod.rs",
            "session reconstruction",
        ),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "approval::",
                "approval.pending",
                "approval.resolved",
                "engine_approvals",
                "approvalItems",
                "observability::",
                "OBSERVABILITY",
                "requiresApproval",
            ],
            label,
        );
    }

    let readme = read_repo_file("README.md");
    assert_absent(
        &readme,
        &[
            "approval.pending",
            "approval.resolved",
            "engine_approvals",
            "approvalItems",
            "observability::",
            "OBSERVABILITY",
            "requiresApproval",
            "AutonomyApprovalPromptMode",
            "EngineApproval",
        ],
        "README old approval/observability primitive docs",
    );

    for (path, label) in [
        (
            "packages/agent/src/domains/session/reconstruction/mod.rs",
            "session reconstruction",
        ),
        (
            "packages/agent/src/domains/settings/profile/types/server.rs",
            "server settings",
        ),
        (
            "packages/agent/src/engine/catalog/capabilities.rs",
            "capability client",
        ),
        (
            "packages/agent/src/engine/authority/grants/mod.rs",
            "grant store",
        ),
        (
            "packages/agent/src/engine/authority/grants/model.rs",
            "grant model",
        ),
        (
            "packages/agent/src/engine/authority/grants/sqlite_codec.rs",
            "grant sqlite codec",
        ),
        ("packages/agent/src/engine/mod.rs", "engine docs/root"),
        (
            "packages/agent/src/engine/kernel/policy.rs",
            "engine policy",
        ),
        (
            "packages/agent/src/engine/primitives/action_summary.rs",
            "action summary projection",
        ),
        (
            "packages/agent/src/engine/primitives/control/actions.rs",
            "control action projection",
        ),
        (
            "packages/agent/src/engine/primitives/grant.rs",
            "grant primitive",
        ),
        (
            "packages/agent/src/engine/primitives/runtime.rs",
            "runtime primitive",
        ),
        (
            "packages/agent/src/engine/primitives/ui/mod.rs",
            "ui primitive target validation",
        ),
        (
            "packages/agent/src/engine/primitives/ui/authoring/actions.rs",
            "generated ui action authoring",
        ),
        (
            "packages/agent/src/engine/primitives/worker.rs",
            "worker primitive",
        ),
        (
            "packages/agent/src/engine/durability/resources/ui_surface.rs",
            "ui surface resource validation",
        ),
        (
            "packages/agent/src/engine/tests/catalog/catalog_discovery.rs",
            "catalog tests",
        ),
        (
            "packages/agent/src/engine/tests/runtime/external_worker.rs",
            "external worker tests",
        ),
        (
            "packages/agent/src/engine/tests/runtime/external_worker_delivery.rs",
            "external worker delivery tests",
        ),
        (
            "packages/agent/src/engine/tests/generated_ui.rs",
            "generated ui tests",
        ),
        (
            "packages/agent/src/engine/tests/authority/invocation_authorization.rs",
            "grant tests",
        ),
        (
            "packages/agent/src/engine/tests/leases_compensation.rs",
            "lease/compensation tests",
        ),
        (
            "packages/agent/src/engine/tests/invocation/meta_primitives.rs",
            "meta primitive tests",
        ),
        (
            "packages/agent/src/engine/tests/durability/resource_contracts.rs",
            "resource tests",
        ),
        (
            "packages/agent/src/engine/tests/runtime/restart_chaos.rs",
            "restart tests",
        ),
        (
            "packages/agent/src/engine/tests/durability/queue_lifecycle.rs",
            "state/queue tests",
        ),
        (
            "packages/agent/src/engine/tests/fixtures/mod.rs",
            "engine test support",
        ),
        (
            "packages/agent/src/engine/kernel/types/mod.rs",
            "engine core types",
        ),
        ("packages/agent/src/transport/engine.rs", "engine transport"),
    ] {
        if !repo_path(path).exists() {
            continue;
        }
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "approval",
                "Approval",
                "approvalPolicy",
                "approvalRequired",
                "approval_required",
                "approvalPromptMode",
                "with_approval_required",
                "AutonomyApprovalPromptMode",
                "ApprovalStatus",
                "engine_approvals",
                "approvalItems",
                "requiresApproval",
                "observability::",
            ],
            label,
        );
    }
}

#[test]
fn capability_policy_settings_plane_is_deleted() {
    assert_repo_path_absent(
        "packages/agent/src/domains/settings/implementation/types/capabilities.rs",
        "capability-specific settings type module",
    );

    for (path, label) in [
        (
            "packages/agent/defaults/profiles/default/profile.toml",
            "default profile",
        ),
        (
            "packages/agent/src/domains/settings/profile/types/mod.rs",
            "settings root type",
        ),
        (
            "packages/agent/src/domains/settings/profile/storage/loader.rs",
            "settings loader tests",
        ),
        (
            "packages/agent/src/shared/foundation/profile/tests.rs",
            "profile overlay tests",
        ),
        ("README.md", "README settings docs"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "settings.capabilities",
                "[settings.capabilities",
                "CapabilitySettings",
                "capabilities.process",
                "capabilities.search",
                "ProcessCapabilitySettings",
                "FilesystemReadCapabilitySettings",
                "BrowserSettings",
                "ComputerUseSettings",
            ],
            label,
        );
    }
}

#[test]
fn public_context_capability_plane_is_deleted() {
    assert_repo_path_absent(
        "packages/agent/src/domains/context",
        "public context domain worker",
    );

    for (path, label) in [
        (
            "packages/agent/src/domains/mod.rs",
            "domain module registry",
        ),
        (
            "packages/agent/src/domains/registration/mod.rs",
            "domain startup registration",
        ),
        (
            "packages/agent/src/domains/registration/catalog.rs",
            "canonical capability catalog",
        ),
        ("README.md", "README context docs"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "context::worker_module",
                "super::context::contract",
                "context::get_snapshot",
                "context::get_detailed_snapshot",
                "context::preview_compaction",
                "context::should_compact",
                "context::confirm_compaction",
                "context::compact",
                "context::can_accept_turn",
                "context::get_audit_trace",
            ],
            label,
        );
    }
}

#[test]
fn fresh_session_store_has_no_product_tables_or_old_shape_migrations() {
    let migration = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    let migration_runner =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/migrations/mod.rs");
    let repositories =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/repositories/mod.rs");
    let row_types =
        read_repo_file("packages/agent/src/domains/session/event_store/sqlite/row_types.rs");
    let session_repo = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/session/mod.rs",
    );

    assert_absent(
        &migration,
        &[
            "branches",
            "device_tokens",
            "cron_jobs",
            "cron_runs",
            "constitution_",
            "profile_migrations",
            "spawning_session_id",
            "spawn_type",
            "spawn_task",
            "origin",
            "source",
            "profile",
            "use_worktree",
        ],
        "fresh session schema",
    );
    assert_absent(
        &migration_runner,
        &[
            "v002_",
            "v004_",
            "v005_",
            "migrated v001",
            "historical-shape",
            "already recorded v001",
        ],
        "migration runner",
    );
    assert_absent(
        &repositories,
        &["branch", "constitution", "device_token"],
        "session store repositories",
    );
    assert_absent(
        &row_types,
        &[
            "BranchRow",
            "DeviceTokenRow",
            "spawning_session_id",
            "spawn_type",
            "spawn_task",
            "origin",
            "source",
            "profile",
            "use_worktree",
        ],
        "session store row types",
    );
    assert_absent(
        &session_repo,
        &[
            "exclude_subagents",
            "list_subagents",
            "update_spawn_info",
            "update_source",
            "NORMAL_PROFILE",
            "use_worktree",
            "source = '",
        ],
        "session repository",
    );
}

use crate::support::*;

#[test]
fn saastc_transport_boundary_has_no_successor_worker_public_surface() {
    let contracts = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    assert!(
        contracts.contains("&[\"discover\", \"inspect\", \"watch\", \"invoke\", \"promote\"]"),
        "public engine transport method set must stay narrow"
    );
    for forbidden in [
        "\"launch\"",
        "\"launch_activation\"",
        "\"launch_from_trigger\"",
        "\"issue_activation\"",
        "\"schedule\"",
        "\"worker_schedule\"",
        "\"worker_activation\"",
        "\"worker_process\"",
        "startupTimeoutMs",
    ] {
        assert!(
            !contracts.contains(forbidden),
            "public engine contracts must not expose successor worker surface: {forbidden}"
        );
    }

    let socket = read_repo_file("packages/agent/src/transport/engine/socket/mod.rs");
    for required in [
        "\"hello\" =>",
        "\"discover\" =>",
        "\"inspect\" =>",
        "\"watch\" =>",
        "\"invoke\" =>",
        "\"promote\" =>",
        "\"subscribe\" =>",
        "\"poll\" =>",
        "\"ack\" =>",
        "\"heartbeat\" =>",
        "\"goodbye\" =>",
    ] {
        assert!(
            socket.contains(required),
            "engine socket dispatch missing retained public/protocol branch {required}"
        );
    }

    let transport_files = [
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/mod.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/agent/src/transport/engine/socket/tests.rs",
        "packages/agent/src/transport/engine/socket/wire.rs",
        "packages/agent/src/transport/runtime/mod.rs",
    ];
    for path in transport_files {
        let source = read_repo_file(path);
        for forbidden in [
            "domains::model::providers",
            "openai",
            "worker::launch_activation",
            "worker::launch_from_trigger",
            "worker::issue_activation",
            "worker_schedule_plan",
            "worker_schedule_tick",
            "worker_schedule_scan_state",
            "activationBundle",
            "postReadyPayload",
            "EngineWorkerScheduleService",
            "scheduler.run()",
            "worker_schedule::",
            "SMAppService",
            "launchd",
            "tron deploy",
            "packages/agent/skills",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not expose or start successor worker/provider/deploy surface: {forbidden}"
            );
        }
    }

    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    for forbidden in [
        "LaunchMessage",
        "ScheduleMessage",
        "ActivationMessage",
        "WorkerActivation",
        "WorkerSchedule",
    ] {
        assert!(
            !wire.contains(forbidden),
            "engine wire DTOs must not define successor worker messages: {forbidden}"
        );
    }
}

#[test]
fn saastc_provider_execute_boundary_is_execute_only_and_fail_closed() {
    let capability_mod = read_repo_file("packages/agent/src/domains/capability/mod.rs");
    let capability_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    let operations = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");
    let executor_grant = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
    );
    let executor_tests = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/tests.rs",
    );
    let openai_converter = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    let openai_converter_tests = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/tests.rs",
    );

    for required in [
        "if spec.operation_key != \"execute\"",
        "unexpected capability operation",
        "`capability::execute`",
        "Provider integrations must expose exactly this one tool",
    ] {
        assert!(
            capability_mod.contains(required),
            "capability module missing execute-only registration guard {required}"
        );
    }
    for required in [
        "pub(crate) const EXECUTE_FUNCTION_ID: &str = \"capability::execute\";",
        "Ok(vec![",
        "CapabilityContract::new(",
        "\"modelPrimitiveName\": \"execute\"",
        "\"additionalProperties\": false",
        "only_execute_is_registered_and_model_facing",
        "execute_schema_exposes_primitive_operations_not_catalog_targets",
        "schema[\"properties\"].get(\"target\").is_none()",
        "schema[\"properties\"].get(\"contractId\").is_none()",
        "schema[\"properties\"].get(\"functionId\").is_none()",
        "schema[\"properties\"].get(\"constraints\").is_none()",
    ] {
        assert!(
            capability_contract.contains(required),
            "capability contract missing execute-only provider marker {required}"
        );
    }
    for forbidden in [
        "worker::launch_activation",
        "worker::launch_from_trigger",
        "worker::issue_activation",
        "worker_schedule_plan",
        "worker_schedule_tick",
        "worker_schedule_scan_state",
    ] {
        assert!(
            !capability_contract.contains(forbidden),
            "provider execute contract must not expose forbidden field or worker surface {forbidden}"
        );
    }

    for required in [
        "validate_execute_context",
        "ActorKind::Agent",
        "ActorKind::System",
        "is_bootstrap_authority_grant_id",
        "execute_operation",
        "\"resource_create\"",
        "\"resource_list\"",
        "\"replay_manifest\"",
        "capability::execute cannot read or write system-scoped resources",
        "capability::execute requires a derived least-privilege authority grant",
    ] {
        assert!(
            operations.contains(required),
            "execute operations missing retained authority/direct-operation guard {required}"
        );
    }
    for forbidden in [
        "catalog_search",
        "catalog::inspect",
        "targetFunction",
        "launch_activation",
        "launch_from_trigger",
        "worker_schedule",
        "activationBundle",
        "providerMetadata",
    ] {
        assert!(
            !operations.contains(forbidden),
            "execute operations must not route through successor/provider surface {forbidden}"
        );
    }

    for required in [
        "fn runtime_grant_shape(",
        "target_function_id.as_str() == \"capability::execute\"",
        "Some(\"resource_link\")",
        "remaining_invocations = 4",
        "remaining_invocations = 3",
        "\"executeOperation\": execute_operation(effective_args)",
        "direct_model_target_gets_target_only_child_grant_shape",
        "execute_resource_link_gets_only_nested_resource_link_shape",
    ] {
        assert!(
            executor_grant.contains(required),
            "execute runtime grant missing operation-scoped proof {required}"
        );
    }
    for required in [
        "direct model targets must not inherit nested execute resource/state capabilities",
        "direct model targets must keep only target-required authority scopes",
        "grant.budget[\"remainingInvocations\"], json!(1)",
    ] {
        assert!(
            executor_tests.contains(required),
            "execute idempotency regression test missing direct-target grant proof {required}"
        );
    }

    for required in [
        "primitive_execute_capabilities(capabilities)",
        "capability.name == \"execute\"",
        "Use ONLY this model-facing tool",
    ] {
        assert!(
            openai_converter.contains(required),
            "OpenAI converter missing execute-only provider guard {required}"
        );
    }
    for forbidden in [
        "hosted",
        "tool_search",
        "computer_use",
        "worker_schedule",
        "activationBundle",
        "providerMetadata",
        "runtimeMetadata",
    ] {
        assert!(
            !openai_converter.contains(forbidden),
            "OpenAI converter must not expose hidden/provider worker surface {forbidden}"
        );
    }
    for required in [
        "convert_tools_v2_ignores_non_execute_capabilities",
        "make_tool(\"inspect\"",
        "make_tool(\"launch_activation\"",
        "assert_eq!(result.len(), 1)",
        "assert_eq!(name, \"execute\")",
        "assert!(!result.contains(\"- **inspect**\"))",
        "assert!(result.contains(\"Do not send `target`\"))",
    ] {
        assert!(
            openai_converter_tests.contains(required),
            "OpenAI converter tests missing execute-only regression {required}"
        );
    }
}

#[test]
fn saastc_invocation_host_keeps_single_governed_promotion_path() {
    let catalog_handle =
        read_repo_file("packages/agent/src/engine/invocation/host/catalog_handle.rs");
    let meta = read_repo_file("packages/agent/src/engine/invocation/host/meta.rs");
    let meta_invocation =
        read_repo_file("packages/agent/src/engine/invocation/host/meta_invocation.rs");
    let promotion_governance =
        read_repo_file("packages/agent/src/engine/invocation/host/promotion_governance.rs");
    let runtime_host = read_repo_file("packages/agent/src/engine/invocation/host/runtime_host.rs");
    let trigger_tests = read_repo_file("packages/agent/src/engine/tests/runtime/triggers.rs");

    assert!(
        !catalog_handle.contains("pub async fn promote_function_visibility"),
        "EngineHostHandle must not expose a direct promotion shortcut around engine::promote"
    );
    assert!(
        trigger_tests.contains("host.catalog_mut()")
            && trigger_tests.contains(".promote_function_visibility(")
            && trigger_tests.contains("None,"),
        "legacy direct promotion usage should be isolated to local test setup only"
    );

    for required in [
        "pub(super) const PROMOTE_FUNCTION: &str = \"engine::promote\";",
        ".with_required_authority(AuthorityRequirement::scope(\"engine.promote\"))",
        "\"decisionResourceId\"",
        "\"evidenceResourceIds\"",
        "\"candidateResourceIds\"",
        "\"promotionReason\"",
        "\"additionalProperties\": false",
    ] {
        assert!(
            meta.contains(required),
            "engine::promote contract missing governance requirement {required}"
        );
    }

    let validate_position = meta_invocation
        .find("self.validate_promotion_governance(")
        .expect("engine::promote must validate governance refs");
    let mutate_position = meta_invocation
        .find("self.catalog.promote_function_visibility(")
        .expect("engine::promote must perform the catalog visibility mutation");
    assert!(
        validate_position < mutate_position,
        "engine::promote must validate decision/evidence/candidate resources before mutation"
    );
    for required in [
        "if function.visibility != VisibilityScope::Session",
        "\"cannot promote function from a different session\"",
        "VisibilityScope::Workspace | VisibilityScope::System",
        "Some(governance_refs.redacted_catalog_metadata(&target))",
    ] {
        assert!(
            meta_invocation.contains(required),
            "engine::promote missing fail-closed host guard {required}"
        );
    }

    for required in [
        "ensure_payload_idempotency_matches_context(invocation)?",
        "ensure_target_authority(&actor, target, workspace_id)?",
        "require_resource(&resources, &refs.decision_resource_id)?",
        "ensure_decision_approves(&decision, function, target, workspace_id)?",
        "ensure_evidence_verified(&inspection)?",
        "ensure_candidate_kind(&inspection)?",
        "ensure_candidates_are_chained(&decision, &evidence, &candidates)?",
        "\"workspace promotion requires engine.promote.workspace authority\"",
        "\"system promotion requires admin authority\"",
    ] {
        assert!(
            promotion_governance.contains(required),
            "promotion governance missing retained authority/resource proof {required}"
        );
    }

    for required in [
        "fn derive_authority_grant(",
        ".grants",
        ".derive(request)",
        "fn store_worker_activation_bundle(",
        ".worker_activation_bundles",
        ".store(",
    ] {
        assert!(
            runtime_host.contains(required),
            "primitive runtime host missing retained store boundary {required}"
        );
    }
    for forbidden in [
        "tokio::spawn",
        "launchd",
        "SMAppService",
        "tron deploy",
        "providerMetadata",
        "postReadyPayload",
    ] {
        assert!(
            !runtime_host.contains(forbidden),
            "primitive runtime host must not start autonomous/public/deploy surface {forbidden}"
        );
    }
}

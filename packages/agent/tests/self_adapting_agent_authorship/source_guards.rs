use super::support::{git_ls_files, read_repo_file, repo_path};

#[test]
fn saa_execute_remains_the_only_provider_visible_tool() {
    let contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    for required in [
        "pub(crate) const EXECUTE_FUNCTION_ID: &str = \"capability::execute\";",
        "modelPrimitiveName\": \"execute\"",
        "author typed resources",
        "only_execute_is_registered_and_model_facing",
        "execute_schema_exposes_primitive_operations_not_catalog_targets",
    ] {
        assert!(
            contract.contains(required),
            "capability contract missing SAA execute-only guard: {required}"
        );
    }
    for forbidden in ["tool", "functionId", "contractId", "target"] {
        assert!(
            !contract.contains(&format!("\"{forbidden}\":")),
            "execute schema must not expose provider field `{forbidden}`"
        );
    }
    let converter = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    assert!(
        converter.contains("catalog-search constraints"),
        "provider clarification must explicitly reject catalog-search constraints"
    );

    let primitive_surface =
        read_repo_file("packages/agent/src/domains/agent/loop/primitive_surface.rs");
    for required in [
        "function.id.as_str() == EXECUTE_FUNCTION_ID",
        ".all(|scope| matches!(scope.as_str(), \"capability.execute\"))",
        "PRIMITIVE_SURFACE_GRANT",
    ] {
        assert!(
            primitive_surface.contains(required),
            "primitive surface must preserve one-tool projection: {required}"
        );
    }
}

#[test]
fn saa_resource_authorship_uses_execute_operations_without_catalog_routing() {
    let operations = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");
    for required in [
        "mod resource;",
        "\"resource_create\" => resource_create(invocation, deps).await?",
        "\"resource_update\" => resource_update(invocation, deps).await?",
        "\"resource_link\" => resource_link(invocation, deps).await?",
        "\"resource_inspect\" => resource_inspect(invocation, deps).await?",
        "\"resource_list\" => resource_list(invocation, deps).await?",
        "validate_resource_scope(invocation)",
        "capability::execute cannot read or write system-scoped resources",
    ] {
        assert!(
            operations.contains(required),
            "execute operation dispatcher missing resource guard: {required}"
        );
    }

    let resource_ops =
        read_repo_file("packages/agent/src/domains/capability/operations/resource.rs");
    for required in [
        "resource_create requires resourcePayload",
        "resource_update requires resourcePayload",
        "workspace resource requires trusted workspace context",
        "resource operation requires trusted current session context",
        "\"resource::create\"",
        "\"resource::update\"",
        "\"resource::link\"",
        "\"resource::inspect\"",
        "\"resource::list\"",
    ] {
        assert!(
            resource_ops.contains(required),
            "resource execute adapter missing guard: {required}"
        );
    }
    for forbidden in ["catalog::list", "engine::discover", "functionId"] {
        assert!(
            !resource_ops.contains(forbidden),
            "resource execute adapter must not route through {forbidden}"
        );
    }
}

#[test]
fn saa_durable_memory_and_rules_are_typed_resources_with_lineage_fields() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    for required in [
        "\"agent_memory\"",
        "\"tron.resource.agent_memory.v1\"",
        "\"statement\"",
        "\"evidenceRefs\"",
        "\"supersededByResourceId\"",
        "\"revokedByResourceId\"",
        "\"agent_rule\"",
        "\"tron.resource.agent_rule.v1\"",
        "\"rule\"",
        "\"decisionRefs\"",
        "\"provenance\"",
    ] {
        assert!(
            definitions.contains(required),
            "resource definitions missing SAA memory/rule field: {required}"
        );
    }

    let workers = read_repo_file("packages/agent/src/engine/primitives/workers.rs");
    for required in [
        ".with_namespace_claim(\"agent_memory\")",
        ".with_namespace_claim(\"agent_rule\")",
    ] {
        assert!(
            workers.contains(required),
            "resource worker missing SAA namespace claim: {required}"
        );
    }
}

#[test]
fn saa_runtime_grant_allows_only_execute_plus_internal_resource_substrate() {
    let grant = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
    );
    for required in [
        "\"resource::create\".to_owned()",
        "\"resource::inspect\".to_owned()",
        "\"resource::link\".to_owned()",
        "\"resource::list\".to_owned()",
        "\"resource::update\".to_owned()",
        "\"resource.read\".to_owned()",
        "\"resource.write\".to_owned()",
        "self_adapting_resource_kinds()",
        "\"agent_memory\"",
        "\"agent_rule\"",
        "\"ui_surface\"",
        "\"patch_proposal\"",
        "\"networkPolicy\": \"none\"",
        "\"canDelegate\": false",
    ] {
        assert!(
            grant.contains(required),
            "capability runtime grant missing SAA guard: {required}"
        );
    }
    for forbidden in [
        "\"engine::promote\".to_owned()",
        "\"worker::register\".to_owned()",
        "\"trigger::create\".to_owned()",
        "\"engine.promote\".to_owned()",
        "\"worker.write\".to_owned()",
    ] {
        assert!(
            !grant.contains(forbidden),
            "SAA runtime grant must not include promotion or live worker authority: {forbidden}"
        );
    }
}

#[test]
fn saa_generated_ui_uses_generic_runtime_surface_renderer() {
    let ui_validation =
        read_repo_file("packages/agent/src/engine/durability/resources/ui_surface.rs");
    for required in [
        "validate_ui_surface_payload",
        "UI_MAX_PAYLOAD_BYTES",
        "scan_ui_value_for_forbidden_content",
        "\"ResourceRef\"",
        "\"InvocationRef\"",
        "\"GrantRef\"",
    ] {
        assert!(
            ui_validation.contains(required),
            "ui_surface validation missing generic runtime guard: {required}"
        );
    }

    let renderer = read_repo_file(
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
    );
    for required in [
        "GeneratedRuntimeSurfaceView",
        "UiSurfaceDTO",
        "GeneratedUIRenderer.validate",
    ] {
        assert!(
            renderer.contains(required),
            "iOS generated runtime surface missing generic renderer text: {required}"
        );
    }

    let renderer_tests =
        read_repo_file("packages/ios-app/Tests/UI/RuntimeSurfaces/GeneratedUIRendererTests.swift");
    for required in [
        "agentCreatedRuntimeSurfaceRendersAndSubmitsCoordinates",
        "kind: \"ui_surface\"",
        "resourceRef",
    ] {
        assert!(
            renderer_tests.contains(required),
            "iOS generated runtime tests missing SAA proof: {required}"
        );
    }
}

#[test]
fn saa_promotion_ready_artifacts_do_not_become_live_workers_or_product_routes() {
    let engine_contracts = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    assert!(
        engine_contracts.contains("engine::promote")
            && engine_contracts.contains("engine.promote.workspace"),
        "SAA promotion boundary must remain explicit through engine::promote"
    );

    let worker_validation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/validation.rs");
    for required in [
        "workerToken.resourceSelectors must be scoped; wildcard selectors are not allowed",
        "session-visible workers require workerToken.sessionId binding",
        "namespace_claim_matches_value",
    ] {
        assert!(
            worker_validation.contains(required),
            "external worker boundary missing fail-closed guard: {required}"
        );
    }

    assert!(
        !repo_path("packages/agent/skills").exists(),
        "SAA must not reintroduce repo-managed first-party skills"
    );

    let tracked = git_ls_files();
    for forbidden_path in [
        "packages/agent/src/domains/capability/registry",
        "packages/agent/src/engine/primitives/module",
        "packages/agent/skills",
    ] {
        assert!(
            !tracked.iter().any(|path| path.starts_with(forbidden_path)),
            "SAA must not restore retired product/worker-pack path {forbidden_path}"
        );
    }
}

#[test]
fn saa_source_has_no_boot_time_autonomous_mutation_loop_or_deploy_path() {
    let mut offenders = Vec::new();
    for path in git_ls_files() {
        if !(path.starts_with("packages/agent/src/")
            || path.starts_with("packages/ios-app/Sources/")
            || path.starts_with("packages/mac-app/Sources/"))
        {
            continue;
        }
        if !(path.ends_with(".rs") || path.ends_with(".swift")) {
            continue;
        }
        let content = read_repo_file(&path);
        for forbidden in [
            "self_adapting_background_loop",
            "autonomous_background_mutation",
            "auto_deploy",
            "tron deploy",
            "cmd_deploy(",
            "packages/agent/skills",
        ] {
            if content.contains(forbidden) {
                offenders.push(format!("{path}: {forbidden}"));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "SAA source must not add boot-time mutation/deploy/managed-skill paths:\n{}",
        offenders.join("\n")
    );
}

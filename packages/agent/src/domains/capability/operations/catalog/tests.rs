use super::*;

fn assert_provider_output_contract(discovery: &Value, operation: &str, profile: &str) {
    let schema = &discovery["outputSchema"];
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(schema["properties"]["operation"]["const"], operation);
    assert_eq!(schema["properties"]["profile"]["const"], profile);
    assert_eq!(
        schema["schemaCompleteness"],
        "exact_provider_operation_output"
    );
    assert!(schema["semanticEvidenceContract"].is_object());
    assert!(schema.get("details").is_none());
}

#[test]
fn catalog_inspect_normalizes_model_facing_log_alias() {
    let (payload, alias) = normalize_catalog_inspect_payload(&json!({
        "kind": "function",
        "id": "execute::log_recent"
    }));

    assert_eq!(payload["id"], "logs::recent");
    assert_eq!(alias.as_deref(), Some("execute::log_recent"));
}

#[test]
fn catalog_inspect_normalizes_direct_catalog_operation_aliases() {
    let (payload, alias) = normalize_catalog_inspect_payload(&json!({
        "kind": "function",
        "id": "git_status"
    }));

    assert_eq!(payload["id"], "git::status");
    assert_eq!(alias.as_deref(), Some("git_status"));
}

#[test]
fn catalog_inspect_detects_execute_operation_aliases_before_generic_schema() {
    let (operation, alias) = execute_operation_inspect_target(&json!({
        "kind": "function",
        "id": "execute::capability_shadow_trial_evidence_inspect"
    }))
    .expect("execute operation alias");

    assert_eq!(operation, "capability_shadow_trial_evidence_inspect");
    assert_eq!(alias, "execute::capability_shadow_trial_evidence_inspect");

    let discovery = execute_operation_inspect_projection_with_options(&operation, &alias, true);
    assert_eq!(discovery["kind"], "execute_operation");
    assert_eq!(
        discovery["id"],
        "execute::capability_shadow_trial_evidence_inspect"
    );
    assert_eq!(
        discovery["operation"],
        "capability_shadow_trial_evidence_inspect"
    );
    assert_eq!(discovery["providerCallable"], true);
    assert_eq!(
        discovery["modelFacingInvocation"]["arguments"]["operation"],
        "capability_shadow_trial_evidence_inspect"
    );
    assert_eq!(
        discovery["schema"]["requiredPayloadFields"],
        json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
    );
    assert_eq!(
        discovery["inputSchema"]["required"],
        json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
    );
    assert_eq!(
        discovery["inputSchema"]["properties"]["operation"]["const"],
        "capability_shadow_trial_evidence_inspect"
    );
    assert_eq!(discovery["inputSchema"]["additionalProperties"], false);
    assert_eq!(
        discovery["inputSchema"]["properties"]["capabilityShadowTrialEvidenceResourceId"]["type"],
        "string"
    );
    assert_provider_output_contract(
        &discovery,
        "capability_shadow_trial_evidence_inspect",
        "governance",
    );
    assert_eq!(
        discovery["agentUsage"]["effect"]["readOnlyInspectionSafe"],
        true
    );
}

#[test]
fn catalog_inspect_defaults_to_one_compact_input_contract() {
    let discovery = execute_operation_inspect_projection_with_options(
        "git_status",
        "execute::git_status",
        false,
    );

    assert!(discovery.get("inputSchema").is_some());
    assert!(discovery.get("outputSchema").is_none());
    assert!(discovery["schema"].get("inputSchema").is_none());
    assert!(discovery["schema"].get("outputSchema").is_none());
    assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
}

#[test]
fn catalog_bootstrap_contracts_are_closed_and_complete() {
    let inspect = execute_operation_inspect_projection("catalog_inspect", "catalog_inspect");
    assert_eq!(
        inspect["inputSchema"]["required"],
        json!(["operation", "kind", "id"])
    );
    assert_eq!(inspect["inputSchema"]["additionalProperties"], false);
    assert_eq!(
        inspect["inputSchema"]["schemaCompleteness"],
        "exact_structural_contract"
    );

    let search = execute_operation_inspect_projection("catalog_search", "catalog_search");
    assert_eq!(search["inputSchema"]["additionalProperties"], false);
    assert!(search["inputSchema"]["properties"].get("text").is_some());
    assert!(search["inputSchema"]["properties"].get("command").is_none());
}

#[test]
fn every_supported_operation_projects_only_its_canonical_contracts() {
    for operation in supported_operation_names() {
        let canonical_input = super::super::operation_contract::exact_input_schema(operation)
            .expect("supported operation input contract");
        let canonical_output = super::super::operation_contract::exact_output_schema(operation)
            .expect("supported operation output contract");
        let discovery = execute_operation_inspect_projection_with_options(
            operation,
            &format!("execute::{operation}"),
            true,
        );

        assert_eq!(
            discovery["inputSchema"], canonical_input,
            "catalog input contract drifted for {operation}"
        );
        assert_eq!(
            discovery["outputSchema"], canonical_output,
            "catalog output contract drifted for {operation}"
        );
        assert_eq!(
            discovery["inputSchema"]["additionalProperties"], false,
            "catalog input contract must be closed for {operation}"
        );
        assert_eq!(
            discovery["inputSchema"]["schemaCompleteness"], "exact_structural_contract",
            "catalog input contract must be exact for {operation}"
        );
        assert_eq!(
            discovery["schema"]["requiredPayloadFields"], discovery["inputSchema"]["required"],
            "required fields must derive from the canonical schema for {operation}"
        );
    }
}

#[test]
#[should_panic(expected = "has no canonical input contract")]
fn missing_canonical_operation_contract_fails_loudly() {
    let _ = execute_operation_input_schema("not_registered");
}

#[test]
fn catalog_inspect_includes_output_contract_only_when_requested() {
    let discovery = execute_operation_inspect_projection_with_options(
        "git_status",
        "execute::git_status",
        true,
    );

    assert!(discovery.get("outputSchema").is_some());
    assert!(discovery["schema"].get("outputSchema").is_none());
}

#[test]
fn catalog_inspect_projects_cockpit_target_operation_optional_field() {
    let discovery = execute_operation_inspect_projection(
        "capability_binding_cockpit_overview",
        "execute::capability_binding_cockpit_overview",
    );

    assert_eq!(
        discovery["schema"]["requiredPayloadFields"],
        json!(["operation"])
    );
    assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
    assert_eq!(
        discovery["inputSchema"]["properties"]["targetOperation"]["type"],
        "string"
    );
    assert!(
        discovery["inputSchema"]["properties"]["targetOperation"]["description"]
            .as_str()
            .expect("targetOperation description")
            .contains("one compact cockpit row")
    );
    assert_eq!(
        discovery["modelFacingInvocation"]["arguments"]["operation"],
        "capability_binding_cockpit_overview"
    );
    let selectors = discovery["agentUsage"]["preflight"]["resourceSelectors"]
        .as_array()
        .expect("resource selectors")
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    for expected in [
        "kind:capability_binding_request",
        "kind:capability_binding_decision",
        "kind:capability_binding_policy",
        "kind:capability_replacement_candidate",
        "kind:capability_route_binding",
        "kind:capability_route_activation",
        "kind:capability_route_event",
        "kind:capability_route_rollback",
        "kind:capability_shadow_trial_request",
        "kind:capability_shadow_trial_decision",
        "kind:capability_shadow_trial_run",
        "kind:capability_shadow_trial_evidence",
    ] {
        assert!(
            selectors.contains(&expected),
            "catalog inspect cockpit preflight missing selector {expected}: {selectors:?}"
        );
    }
    assert_eq!(
        discovery["agentUsage"]["preflight"]["networkPolicy"],
        "none"
    );
    assert_eq!(
        discovery["agentUsage"]["preflight"]["agentStateInherited"],
        false
    );
}

#[test]
fn catalog_inspect_projects_web_operation_contracts() {
    let robots = execute_operation_inspect_projection_with_options(
        "web_robots_check",
        "execute::web_robots_check",
        true,
    );
    assert_eq!(
        robots["schema"]["requiredPayloadFields"],
        json!(["operation", "url", "idempotencyKey"])
    );
    assert_eq!(
        robots["inputSchema"]["required"],
        json!(["operation", "url", "idempotencyKey"])
    );
    assert_eq!(
        robots["inputSchema"]["properties"]["operation"]["const"],
        "web_robots_check"
    );
    assert_eq!(robots["inputSchema"]["properties"]["url"]["format"], "uri");
    assert!(
        robots["inputSchema"]["properties"]["userAgent"]["description"]
            .as_str()
            .expect("userAgent description")
            .contains("omit this field")
    );
    assert!(
        execute_operation_invocation_guidance("web_robots_check")
            .contains("copy webRobotsPolicyVersionId")
    );
    assert!(
        robots["inputSchema"]["properties"]["idempotencyKey"]["description"]
            .as_str()
            .expect("idempotency description")
            .contains("Stable bounded caller idempotency key")
    );
    assert_provider_output_contract(&robots, "web_robots_check", "web");
    assert_eq!(
        robots["outputSchema"]["semanticEvidenceContract"]["requiredFactFieldsOnSuccess"],
        json!([
            "primitiveOperation",
            "status",
            "web.schemaVersion",
            "web.operation",
            "web.webRobotsPolicyResourceId",
            "web.webRobotsPolicyVersionId"
        ])
    );

    let fetch =
        execute_operation_inspect_projection_with_options("web_fetch", "execute::web_fetch", true);
    assert_eq!(
        fetch["schema"]["requiredPayloadFields"],
        json!(["operation", "url", "idempotencyKey"])
    );
    assert_eq!(
        fetch["inputSchema"]["required"],
        json!(["operation", "url", "idempotencyKey"])
    );
    assert_eq!(
        fetch["inputSchema"]["properties"]["operation"]["const"],
        "web_fetch"
    );
    assert_eq!(
        fetch["inputSchema"]["properties"]["webRobotsPolicyResourceId"]["type"],
        json!(["string", "null"])
    );
    assert!(
        fetch["inputSchema"]["properties"]["expectedWebRobotsPolicyVersionId"]["description"]
            .as_str()
            .expect("expected version description")
            .contains("webRobotsPolicyVersionId")
    );
    assert!(
        fetch["inputSchema"]["properties"]["idempotencyKey"]["description"]
            .as_str()
            .expect("idempotency description")
            .contains("Stable bounded caller idempotency key")
    );
    assert!(execute_operation_invocation_guidance("web_fetch").contains("copy"));
    assert!(execute_operation_invocation_guidance("web_fetch").contains("fail closed"));
    assert_provider_output_contract(&fetch, "web_fetch", "web");
    assert_eq!(
        fetch["outputSchema"]["semanticEvidenceContract"]["expectedResourceKinds"],
        json!(["web_source"])
    );
}

#[test]
fn catalog_search_advertises_conditional_web_fetch_evidence_linkage() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "web fetch robots evidence", "limit": 10}),
    );

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    let web_fetch = matches
        .iter()
        .find(|value| value["operation"] == "web_fetch")
        .expect("web_fetch match");
    assert_eq!(
        web_fetch["agentUsage"]["effect"]["priorEvidence"]["mode"],
        "conditional"
    );
    assert_eq!(
        web_fetch["agentUsage"]["effect"]["priorEvidence"]["sourceOperation"],
        "web_robots_check"
    );
    assert_eq!(
        web_fetch["agentUsage"]["effect"]["priorEvidence"]["copyFields"]["webRobotsPolicyVersionId"],
        "web_fetch.expectedWebRobotsPolicyVersionId"
    );
    assert!(
        web_fetch["agentUsage"]["effect"]["priorEvidence"]["failClosed"]
            .as_str()
            .expect("fail closed guidance")
            .contains("before target network I/O")
    );
}

#[test]
fn catalog_inspect_projects_closed_job_operation_contracts() {
    let start = execute_operation_inspect_projection("job_start", "execute::job_start");
    assert_eq!(
        start["schema"]["requiredPayloadFields"],
        json!(["operation", "command", "idempotencyKey"])
    );
    assert_eq!(
        start["inputSchema"]["required"],
        json!(["operation", "command", "idempotencyKey"])
    );
    assert_eq!(start["inputSchema"]["additionalProperties"], false);
    assert_eq!(
        start["inputSchema"]["properties"]["operation"]["const"],
        "job_start"
    );
    assert_eq!(
        start["inputSchema"]["properties"]["command"]["type"],
        "string"
    );
    assert!(
        start["inputSchema"]["properties"]["idempotencyKey"]["description"]
            .as_str()
            .expect("idempotency description")
            .contains("provider-visible in the tool-call payload")
    );
    assert!(
        execute_operation_invocation_guidance("job_start")
            .contains("job_status, job_log, job_list, and trace projections redact")
    );

    for operation in ["job_status", "job_log"] {
        let discovery =
            execute_operation_inspect_projection(operation, &format!("execute::{operation}"));
        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation", "jobResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["required"],
            json!(["operation", "jobResourceId"])
        );
        assert_eq!(discovery["inputSchema"]["additionalProperties"], false);
        assert_eq!(
            discovery["inputSchema"]["properties"]["jobResourceId"]["description"],
            json!(
                "Exact durable job_process resource id returned by job_start or job_list for the current session scope."
            )
        );
        assert!(
            execute_operation_invocation_guidance(operation)
                .contains("job_status/list return provider-safe lifecycle/output refs")
        );
    }
    let status = execute_operation_inspect_projection_with_options(
        "job_status",
        "execute::job_status",
        true,
    );
    assert_provider_output_contract(&status, "job_status", "runtime");
    let exclusions = status["outputSchema"]["semanticEvidenceContract"]["safetyExclusions"]
        .as_array()
        .expect("job safety exclusions");
    assert!(
        exclusions
            .iter()
            .any(|value| value == "raw commands and working directories")
    );
    assert!(
        exclusions
            .iter()
            .any(|value| value == "raw stdout and stderr")
    );

    let list = execute_operation_inspect_projection("job_list", "execute::job_list");
    assert_eq!(
        list["schema"]["requiredPayloadFields"],
        json!(["operation"])
    );
    assert_eq!(list["inputSchema"]["required"], json!(["operation"]));
    assert_eq!(list["inputSchema"]["additionalProperties"], false);
    assert_eq!(
        list["inputSchema"]["properties"]["state"]["enum"],
        json!([
            "running",
            "completed",
            "failed",
            "timed_out",
            "cancelled",
            "archived"
        ])
    );

    let cancel = execute_operation_inspect_projection("job_cancel", "execute::job_cancel");
    assert_eq!(
        cancel["schema"]["requiredPayloadFields"],
        json!(["operation", "jobResourceId", "idempotencyKey"])
    );
    assert_eq!(cancel["inputSchema"]["additionalProperties"], false);
}

#[test]
fn catalog_inspect_projects_closed_process_run_contract() {
    let process = execute_operation_inspect_projection("process_run", "execute::process_run");
    assert_eq!(
        process["schema"]["requiredPayloadFields"],
        json!(["operation", "command", "idempotencyKey"])
    );
    assert_eq!(
        process["inputSchema"]["required"],
        json!(["operation", "command", "idempotencyKey"])
    );
    assert_eq!(process["inputSchema"]["additionalProperties"], false);
    assert_eq!(
        process["inputSchema"]["properties"]["timeoutMs"]["maximum"],
        json!(120000)
    );
    assert_eq!(
        process["inputSchema"]["properties"]["maxOutputBytes"]["maximum"],
        json!(200000)
    );
    assert!(
        execute_operation_invocation_guidance("process_run")
            .contains("prefer job_start followed by job_status/job_log")
    );
}

#[test]
fn catalog_inspect_projects_trace_output_record_schema() {
    let trace_list = execute_operation_inspect_projection_with_options(
        "trace_list",
        "execute::trace_list",
        true,
    );

    assert_eq!(
        trace_list["schema"]["requiredPayloadFields"],
        json!(["operation"])
    );
    assert_eq!(trace_list["inputSchema"]["required"], json!(["operation"]));
    assert_eq!(trace_list["inputSchema"]["additionalProperties"], false);
    assert!(trace_list["inputSchema"]["properties"]["limit"].is_object());
    assert!(trace_list["inputSchema"]["properties"]["traceId"].is_object());
    assert!(trace_list["inputSchema"]["properties"]["recordOperation"].is_object());
    assert_eq!(
        trace_list["inputSchema"]["properties"]["recordStatus"]["enum"],
        json!(["running", "ok", "failed", "timeout"])
    );
    assert_provider_output_contract(&trace_list, "trace_list", "trace_audit");
    assert_eq!(
        trace_list["outputSchema"]["semanticEvidenceContract"]["requiredFactFieldsOnSuccess"],
        json!([
            "primitiveOperation",
            "status",
            "projectionBoundary.providerVisibleProjection",
            "statusSummary.totalRecords"
        ])
    );
    assert_eq!(
        trace_list["outputSchema"]["semanticEvidenceContract"]["expectedCollectionFields"],
        json!(["records"])
    );
    let exclusions = trace_list["outputSchema"]["semanticEvidenceContract"]["safetyExclusions"]
        .as_array()
        .expect("trace safety exclusions");
    assert!(
        exclusions
            .iter()
            .any(|field| field == "raw provider invocation identifiers")
    );
    assert!(
        execute_operation_invocation_guidance("trace_list").contains("trusted runtime context")
    );
    assert!(
        execute_operation_invocation_guidance("trace_list")
            .contains("call it after the operations being audited")
    );
    assert!(
        execute_operation_invocation_guidance("trace_list")
            .contains("provider transcript tool-call ids may be visible")
    );
    assert!(
        execute_operation_invocation_guidance("trace_list")
            .contains("trace projections do not expose raw trace providerInvocationId fields")
    );

    let log_recent = execute_operation_inspect_projection_with_options(
        "log_recent",
        "execute::log_recent",
        false,
    );
    assert!(log_recent["inputSchema"]["properties"]["traceId"].is_object());
    assert!(
        log_recent["inputSchema"]["properties"]
            .get("recordOperation")
            .is_none()
    );

    let trace_get =
        execute_operation_inspect_projection_with_options("trace_get", "execute::trace_get", true);
    assert_eq!(
        trace_get["schema"]["requiredPayloadFields"],
        json!(["operation", "traceRecordId"])
    );
    assert_eq!(
        trace_get["inputSchema"]["required"],
        json!(["operation", "traceRecordId"])
    );
    assert_eq!(trace_get["inputSchema"]["additionalProperties"], false);
    assert!(
        trace_get["inputSchema"]["properties"]["traceRecordId"]["description"]
            .as_str()
            .expect("traceRecordId description")
            .contains("trace record id")
    );
    assert_provider_output_contract(&trace_get, "trace_get", "trace_audit");
    assert_eq!(
        trace_get["outputSchema"]["semanticEvidenceContract"]["requiredFactFieldsOnSuccess"],
        json!([
            "primitiveOperation",
            "status",
            "projectionBoundary.providerVisibleProjection",
            "record.schemaVersion"
        ])
    );
}

#[test]
fn catalog_inspect_projects_shadow_trial_request_required_fields() {
    let request = execute_operation_inspect_projection(
        "capability_shadow_trial_request_record",
        "execute::capability_shadow_trial_request_record",
    );

    assert_eq!(
        request["schema"]["requiredPayloadFields"],
        json!([
            "operation",
            "title",
            "targetOperation",
            "currentBuiltInOwner",
            "ownershipClass",
            "replacementTarget",
            "bindingMode",
            "candidateAdapter",
            "authorityConstraints",
            "contractEvidenceRefs",
            "evidenceRefs",
            "staleVersionGuard",
            "rollbackRef",
            "disableRef",
            "abortRef",
            "rationale",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        request["inputSchema"]["required"],
        request["schema"]["requiredPayloadFields"]
    );
    assert_eq!(
        request["inputSchema"]["properties"]["currentBuiltInOwner"]["type"],
        "string"
    );
}

#[test]
fn catalog_inspect_projects_shadow_trial_record_required_fields() {
    let decision = execute_operation_inspect_projection(
        "capability_shadow_trial_decision_record",
        "execute::capability_shadow_trial_decision_record",
    );
    assert_eq!(decision["kind"], "execute_operation");
    assert_eq!(
        decision["schema"]["requiredPayloadFields"],
        json!([
            "operation",
            "capabilityShadowTrialRequestResourceId",
            "expectedCapabilityShadowTrialRequestVersionId",
            "decision",
            "reason",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        decision["inputSchema"]["required"],
        json!([
            "operation",
            "capabilityShadowTrialRequestResourceId",
            "expectedCapabilityShadowTrialRequestVersionId",
            "decision",
            "reason",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        decision["inputSchema"]["properties"]["capabilityShadowTrialRequestResourceId"]["type"],
        "string"
    );
    assert_eq!(
        decision["inputSchema"]["properties"]["expectedCapabilityShadowTrialRequestVersionId"]["type"],
        "string"
    );

    let run = execute_operation_inspect_projection(
        "capability_shadow_trial_run_record",
        "execute::capability_shadow_trial_run_record",
    );
    assert_eq!(run["kind"], "execute_operation");
    assert_eq!(
        run["schema"]["requiredPayloadFields"],
        json!([
            "operation",
            "capabilityShadowTrialDecisionResourceId",
            "expectedCapabilityShadowTrialDecisionVersionId",
            "builtInProjection",
            "candidateProjection",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        run["inputSchema"]["required"],
        json!([
            "operation",
            "capabilityShadowTrialDecisionResourceId",
            "expectedCapabilityShadowTrialDecisionVersionId",
            "builtInProjection",
            "candidateProjection",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        run["inputSchema"]["properties"]["capabilityShadowTrialDecisionResourceId"]["type"],
        "string"
    );
    assert_eq!(
        run["inputSchema"]["properties"]["expectedCapabilityShadowTrialDecisionVersionId"]["type"],
        "string"
    );
    assert_eq!(
        run["inputSchema"]["properties"]["builtInProjection"]["type"],
        "object"
    );
    assert_eq!(
        run["inputSchema"]["properties"]["builtInProjection"]["required"],
        json!([
            "operation",
            "status",
            "headState",
            "indexState",
            "worktreeState",
            "evidenceRef"
        ])
    );
    assert_eq!(
        run["inputSchema"]["properties"]["builtInProjection"]["properties"]["operation"]["const"],
        "git_status"
    );
    assert_eq!(
        run["inputSchema"]["properties"]["candidateProjection"]["type"],
        "object"
    );
    assert_eq!(
        run["inputSchema"]["properties"]["trialRunOutcome"]["enum"],
        json!(["completed", "aborted", "disabled"])
    );
}

#[test]
fn catalog_inspect_uses_exact_repository_tree_inspect_resource_field() {
    let discovery = execute_operation_inspect_projection(
        "repository_tree_inspect",
        "execute::repository_tree_inspect",
    );

    assert_eq!(
        discovery["schema"]["requiredPayloadFields"],
        json!(["operation", "repositoryTreeResourceId"])
    );
    assert_eq!(
        discovery["inputSchema"]["required"],
        json!(["operation", "repositoryTreeResourceId"])
    );
    assert_eq!(
        discovery["inputSchema"]["properties"]["repositoryTreeResourceId"]["type"],
        "string"
    );
    assert!(
        !discovery.to_string().contains("<exactResourceIdField>"),
        "model-facing schema must never require the agent to infer inspect resource field names"
    );
}

#[test]
fn catalog_inspect_exposes_exact_repository_tree_snapshot_contract() {
    let discovery = execute_operation_inspect_projection(
        "repository_tree_snapshot",
        "execute::repository_tree_snapshot",
    );

    assert_eq!(
        discovery["schema"]["requiredPayloadFields"],
        json!([
            "operation",
            "repositoryRef",
            "rootRef",
            "treeObjectRef",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        discovery["inputSchema"]["additionalProperties"],
        json!(false)
    );
    assert_eq!(
        discovery["inputSchema"]["properties"]["repositoryRef"]["type"],
        "object"
    );
    assert!(
        discovery["inputSchema"]["properties"]["repositoryRef"]["description"]
            .as_str()
            .expect("repository ref description")
            .contains("including kind")
    );
    assert_eq!(
        discovery["inputSchema"]["properties"]["rootRef"]["type"],
        "object"
    );
    assert!(
        discovery["inputSchema"]["properties"]["rootRef"]["description"]
            .as_str()
            .expect("root ref description")
            .contains("Passing only .id is invalid")
    );
    assert!(
        discovery["inputSchema"]["properties"]["headRef"]["description"]
            .as_str()
            .expect("head ref description")
            .contains("including kind")
    );
    assert!(
        discovery["inputSchema"]["properties"]["treeObjectRef"]["description"]
            .as_str()
            .expect("tree object description")
            .contains("repositoryTreeSnapshotInput.treeObjectRef")
    );
    assert!(
        discovery["inputSchema"]["properties"]["pathEntries"]["description"]
            .as_str()
            .expect("path entry description")
            .contains("never raw file contents")
    );
    let guidance = execute_operation_invocation_guidance("repository_tree_snapshot");
    assert!(guidance.contains("Copy complete repositoryRef/rootRef/headRef objects"));
    assert!(guidance.contains("including kind"));
    assert!(guidance.contains("passing only .id values is invalid"));
}

#[test]
fn catalog_inspect_exposes_exact_repository_tree_list_contract() {
    let discovery = execute_operation_inspect_projection(
        "repository_tree_list",
        "execute::repository_tree_list",
    );

    assert_eq!(
        discovery["schema"]["requiredPayloadFields"],
        json!(["operation"])
    );
    assert_eq!(
        discovery["inputSchema"]["additionalProperties"],
        json!(false)
    );
    assert_eq!(
        discovery["inputSchema"]["properties"]["repositoryRefId"]["description"],
        "Optional bounded repository ref id filter; unsupported aliases are rejected."
    );
    assert!(
        !discovery.to_string().contains("repositoryTreeRefId"),
        "catalog must not suggest unsupported repository tree aliases"
    );
}

#[test]
fn catalog_inspect_projects_goal_question_required_fields() {
    let goal_create = execute_operation_inspect_projection("goal_create", "execute::goal_create");
    assert_eq!(
        goal_create["schema"]["requiredPayloadFields"],
        json!(["operation", "objective", "idempotencyKey"])
    );
    assert_eq!(
        goal_create["inputSchema"]["required"],
        json!(["operation", "objective", "idempotencyKey"])
    );

    let goal_cancel = execute_operation_inspect_projection("goal_cancel", "execute::goal_cancel");
    assert_eq!(
        goal_cancel["schema"]["requiredPayloadFields"],
        json!(["operation", "goalResourceId", "reason", "idempotencyKey"])
    );
    assert_eq!(
        goal_cancel["inputSchema"]["required"],
        json!(["operation", "goalResourceId", "reason", "idempotencyKey"])
    );

    let question_create =
        execute_operation_inspect_projection("question_create", "execute::question_create");
    assert_eq!(
        question_create["schema"]["requiredPayloadFields"],
        json!(["operation", "prompt", "idempotencyKey"])
    );
    assert_eq!(
        question_create["inputSchema"]["required"],
        json!(["operation", "prompt", "idempotencyKey"])
    );

    let question_answer =
        execute_operation_inspect_projection("question_answer", "execute::question_answer");
    assert_eq!(
        question_answer["schema"]["requiredPayloadFields"],
        json!([
            "operation",
            "questionResourceId",
            "expectedQuestionVersionId",
            "answerText",
            "reason",
            "idempotencyKey"
        ])
    );
    assert_eq!(
        question_answer["inputSchema"]["required"],
        json!([
            "operation",
            "questionResourceId",
            "expectedQuestionVersionId",
            "answerText",
            "reason",
            "idempotencyKey"
        ])
    );
}

#[test]
fn catalog_inspect_has_no_placeholder_fields_for_supported_inspect_operations() {
    for operation in supported_operation_names()
        .iter()
        .copied()
        .filter(|operation| operation.ends_with("_inspect"))
    {
        let discovery =
            execute_operation_inspect_projection(operation, &format!("execute::{operation}"));
        let rendered = discovery.to_string();
        assert!(
            !rendered.contains("<exactResourceIdField>"),
            "{operation} exposed a placeholder resource id field"
        );

        let required = discovery["schema"]["requiredPayloadFields"]
            .as_array()
            .expect("required payload fields");
        if operation != "catalog_inspect" {
            assert!(
                required.iter().any(|field| {
                    field
                        .as_str()
                        .is_some_and(|field| field != "operation" && field.ends_with("ResourceId"))
                }),
                "{operation} should advertise its exact resource id field"
            );
        }
    }
}

#[test]
fn catalog_inspect_documents_git_status_evidence_contract() {
    let discovery = execute_operation_inspect_projection_with_options(
        "git_status",
        "execute::git_status",
        true,
    );

    assert_eq!(discovery["inputSchema"]["additionalProperties"], false);
    assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
    assert_provider_output_contract(&discovery, "git_status", "git");
    assert_eq!(
        discovery["outputSchema"]["semanticEvidenceContract"]["requiredFactFieldsOnSuccess"],
        json!([
            "primitiveOperation",
            "status",
            "git.schemaVersion",
            "git.operation",
            "git.repositoryNavigation.available",
            "git.repositoryNavigation.referenceClass",
            "git.repositoryNavigation.durableResource",
            "git.repositoryNavigation.resourceCreationPerformed",
            "git.repositoryNavigation.consumerOperation"
        ])
    );
    assert_eq!(
        discovery["outputSchema"]["semanticEvidenceContract"]["expectedResourceKinds"],
        json!([])
    );
    assert_eq!(
        discovery["agentUsage"]["preflight"]["authorityScopes"],
        json!(["git.read", "resource.read"])
    );
    assert_eq!(
        discovery["agentUsage"]["preflight"]["networkPolicy"],
        "none"
    );
}

#[test]
fn catalog_inspect_qualifies_runtime_routing_metadata_for_read_only_invocation() {
    let discovery = execute_operation_inspect_projection("git_status", "execute::git_status");

    assert_eq!(
        discovery["capabilityPool"]["currentInvocation"]["guidance"],
        "For this operation-specific invocation, follow the input schema and preflight fields. Replacement/routing classification is informational unless the user task explicitly asks to replace, shadow, activate, disable, or roll back this operation."
    );
    assert_eq!(
        discovery["capabilityPool"]["currentInvocation"]["effect"]["mode"],
        "read_only"
    );
    assert_eq!(
        discovery["capabilityPool"]["replacementWorkflowBoundary"]["appliesOnlyWhen"],
        "explicit_replacement_shadow_route_or_rollback_workflow"
    );
    assert_eq!(
        discovery["capabilityPool"]["replacementWorkflowBoundary"]["notRequiredFor"],
        "normal_read_only_or_session_work_invocation"
    );
    assert_eq!(
        discovery["capabilityPool"]["purpose"],
        "agent_inspects_or_changes_scoped_git_state_by_operation_effect"
    );
}

#[test]
fn catalog_search_annotations_bridge_catalog_ids_to_execute_operations() {
    let mut discovery = json!({
        "functions": [
            {"id": "logs::recent"},
            {"id": "git::status"},
            {"id": "capability_binding::cockpit_overview"},
            {"id": "capability::execute"}
        ]
    });

    annotate_model_facing_invocation(&mut discovery, &json!({}));

    assert_eq!(
        discovery["functions"][0]["modelFacingInvocation"]["operation"],
        "log_recent"
    );
    assert_eq!(
        discovery["functions"][1]["modelFacingInvocation"]["operation"],
        "git_status"
    );
    assert_eq!(
        discovery["functions"][1]["modelFacingInvocation"]["providerSchemaInspectId"],
        "execute::git_status"
    );
    assert_eq!(
        discovery["functions"][1]["modelFacingInvocation"]["preferredSchemaInspection"]["arguments"]
            ["id"],
        "execute::git_status"
    );
    assert_eq!(discovery["functions"][1]["agentUsage"]["callable"], true);
    assert_eq!(
        discovery["functions"][2]["modelFacingInvocation"]["operation"],
        "capability_binding_cockpit_overview"
    );
    assert!(
        discovery["functions"][2]["agentUsage"]["preflight"]["resourceSelectors"]
            .as_array()
            .expect("resource selectors")
            .iter()
            .any(|selector| selector == "kind:capability_binding_decision")
    );
    assert!(
        discovery["functions"][2]["agentUsage"]["preflight"]["resourceSelectors"]
            .as_array()
            .expect("resource selectors")
            .iter()
            .any(|selector| selector == "kind:capability_route_event")
    );
    assert_eq!(
        discovery["functions"][0]["capabilityPool"]["surface"],
        "catalog_function"
    );
    assert_eq!(
        discovery["functions"][0]["modelFacingInvocation"]["capabilityPool"]["surface"],
        "agent_operation"
    );
    assert_eq!(
        discovery["functions"][0]["modelFacingInvocation"]["capabilityPool"]["audience"],
        "agent_diagnostics"
    );
    assert!(
        discovery["functions"][3]
            .get("modelFacingInvocation")
            .is_none()
    );
    assert_eq!(
        discovery["functions"][3]["capabilityPool"]["audience"],
        "session_work"
    );
    assert_eq!(
        discovery["functions"][3]["capabilityPool"]["agentDefaultVisibility"],
        "search_visible"
    );
    assert_eq!(discovery["functions"][3]["providerCallable"], false);
    assert!(
        discovery["functions"][3]["providerCallableReason"]
            .as_str()
            .unwrap_or_default()
            .contains("capability::execute")
    );
    assert_eq!(
        discovery["functions"][3]["agentUsage"]["defaultUse"],
        "inspect_only"
    );
    assert_eq!(
        discovery["modelFacingGuidance"]["supportedExecuteOperations"]
            .as_array()
            .expect("operations")
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>(),
        supported_operation_names().to_vec()
    );
}

#[test]
fn catalog_search_read_only_guidance_filters_generic_supported_operations() {
    let mut discovery = json!({"functions": []});

    annotate_model_facing_invocation(&mut discovery, &json!({"effectClass": "pure_read"}));

    let operations = discovery["modelFacingGuidance"]["supportedExecuteOperations"]
        .as_array()
        .expect("operations")
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    assert!(operations.contains(&"catalog_search"));
    assert!(operations.contains(&"catalog_inspect"));
    assert!(operations.contains(&"git_status"));
    assert!(operations.contains(&"capability_binding_cockpit_overview"));
    for mutating in [
        "state_set",
        "filesystem_write",
        "filesystem_edit",
        "filesystem_apply_patch",
        "git_stage",
        "git_commit",
        "capability_route_activate",
    ] {
        assert!(
            !operations.contains(&mutating),
            "pure-read supported-operation guidance must not include {mutating}"
        );
    }
    assert_eq!(
        discovery["modelFacingGuidance"]["supportedExecuteOperationsFilter"]["mode"],
        "read_only_inspection_safe"
    );
}

#[test]
fn catalog_search_adds_exact_execute_operation_matches() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(&mut discovery, &json!({"text": "trace_list", "limit": 10}));

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    assert_eq!(matches[0]["operation"], "trace_list");
    assert_eq!(matches[0]["matchKind"], "exact");
    assert_eq!(matches[0]["tool"], "capability::execute");
    assert_eq!(matches[0]["arguments"]["operation"], "trace_list");
    assert_eq!(matches[0]["catalogInspectId"], "execute::trace_list");
    assert_eq!(
        matches[0]["schemaInspection"]["arguments"]["id"],
        "execute::trace_list"
    );
    assert_eq!(
        discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
        "execute::trace_list"
    );
    assert_eq!(
        discovery["agentNextStep"]["priority"],
        "inspect_execute_operation_schema_first"
    );
    assert_eq!(
        matches[0]["capabilityPool"]["audience"],
        "agent_diagnostics"
    );
    assert_eq!(
        matches[0]["capabilityPool"]["replacementClass"],
        "kernel_evolution_only"
    );
    assert_eq!(matches[0]["agentUsage"]["callable"], true);
    assert_eq!(
        discovery["executeOperationSearch"]["totalMatches"],
        matches.len()
    );
}

#[test]
fn catalog_search_adds_multiple_exact_execute_operation_matches() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "capability_binding_request_list capability_binding_decision_list capability_binding_policy_list", "limit": 10}),
    );

    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        operations,
        vec![
            "capability_binding_decision_list",
            "capability_binding_policy_list",
            "capability_binding_request_list",
        ]
    );
    assert!(
        discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .all(|value| value["matchKind"] == "exact")
    );
    assert_eq!(
        discovery["executeOperationSearch"]["canonicalQuery"]
            .as_str()
            .expect("canonical query"),
        "capability_binding_request_list_capability_binding_decision_list_capability_binding_policy_list"
    );
    assert!(
        discovery["executeOperationSearch"]["terms"]
            .as_array()
            .expect("terms")
            .iter()
            .any(|term| term == "request")
    );
}

#[test]
fn catalog_search_advertises_write_operations_as_not_read_only_safe() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "capability_shadow_trial_request_record", "limit": 10}),
    );

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    assert_eq!(
        matches[0]["operation"],
        "capability_shadow_trial_request_record"
    );
    assert_eq!(matches[0]["matchKind"], "exact");
    assert_eq!(matches[0]["agentUsage"]["effect"]["mode"], "metadata_write");
    assert_eq!(
        matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
        false
    );
    assert_eq!(matches[0]["agentUsage"]["effect"]["mutatesState"], true);
    assert!(
        matches[0]["agentUsage"]["effect"]["readOnlyInstruction"]
            .as_str()
            .expect("effect instruction")
            .contains("do not call during read-only inspection")
    );
    assert!(
        matches[0]["agentUsage"]["preflight"]["readOnlyInstruction"]
            .as_str()
            .expect("preflight instruction")
            .contains("do not call during read-only inspection")
    );
}

#[test]
fn catalog_search_pure_read_filter_excludes_mutating_operation_matches() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "effectClass": "pure_read",
            "limit": 20,
            "text": "resource list inspect current workspace session media import preview repository tree program execution prompt artifact module validation install dependency notification schedule question goal web source"
        }),
    );

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    assert!(!matches.is_empty());
    assert!(
        matches.iter().all(|value| {
            value["agentUsage"]["effect"]["readOnlyInspectionSafe"] == true
                && value["agentUsage"]["effect"]["mutatesState"] == false
        }),
        "pure_read searches must not return mutating execute operations: {matches:#?}"
    );
    let operations = matches
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert!(!operations.contains(&"module_program_execution_start"));
    assert!(!operations.contains(&"repository_tree_snapshot"));
    assert!(operations.contains(&"import_preview_list"));
    assert!(operations.contains(&"repository_tree_list"));
}

#[test]
fn catalog_search_namespace_prefix_uses_capability_pool_family() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "effectClass": "pure_read",
            "limit": 50,
            "namespacePrefix": "context_control"
        }),
    );

    assert_eq!(
        discovery["executeOperationSearch"]["query"],
        "context_control"
    );
    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    let operations = matches
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    for expected in [
        "context_control_status",
        "context_control_action_list",
        "context_control_action_inspect",
        "context_survivor_list",
        "context_exclusion_list",
    ] {
        assert!(
            operations.contains(&expected),
            "namespace family search should include {expected}: {operations:?}"
        );
    }
    for mutating in [
        "context_control_snapshot",
        "context_control_compact",
        "context_control_clear",
        "context_policy_snapshot",
        "context_survivor_record",
        "context_exclusion_record",
    ] {
        assert!(
            !operations.contains(&mutating),
            "pure_read namespace search must exclude mutating operation {mutating}: {operations:?}"
        );
    }
    assert!(matches.iter().all(|value| {
        value["agentUsage"]["effect"]["readOnlyInspectionSafe"] == true
            && value["agentUsage"]["effect"]["mutatesState"] == false
    }));
    assert!(
        matches
            .iter()
            .any(|value| value["matchKind"] == "namespace"),
        "family-owned operations without the context_control prefix should be namespace matches"
    );
    let excluded_operations = discovery["effectClassExcludedOperationMatches"]
        .as_array()
        .expect("effect-class exclusions")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert!(excluded_operations.contains(&"context_policy_snapshot"));
    assert!(excluded_operations.contains(&"context_control_snapshot"));
    assert_eq!(
        discovery["executeOperationSearch"]["effectClassExcludedMatches"],
        json!(excluded_operations.len())
    );
}

#[test]
fn catalog_search_advertises_conformance_as_report_write() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "catalog_conformance", "limit": 10}),
    );

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    assert_eq!(matches[0]["operation"], "catalog_conformance");
    assert_eq!(matches[0]["matchKind"], "exact");
    assert_eq!(matches[0]["agentUsage"]["effect"]["mode"], "metadata_write");
    assert_eq!(
        matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
        false
    );
    assert_eq!(matches[0]["agentUsage"]["effect"]["writesResource"], true);
    assert!(
        matches[0]["agentUsage"]["effect"]["readOnlyInstruction"]
            .as_str()
            .expect("effect instruction")
            .contains("do not call during read-only inspection")
    );
    let inspect =
        execute_operation_inspect_projection("catalog_conformance", "execute::catalog_conformance");
    assert_eq!(
        inspect["inputSchema"]["required"],
        json!(["operation", "idempotencyKey"])
    );
    assert!(
        execute_operation_invocation_guidance("catalog_conformance")
            .contains("idempotent durable catalog_discovery_report")
    );
}

#[test]
fn catalog_search_read_only_reports_supported_mutating_matches_as_excluded() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "effectClass": "read_only",
            "limit": 10,
            "text": "context_policy_snapshot"
        }),
    );

    assert_eq!(
        discovery["executeOperationSearch"]["totalMatches"],
        json!(0)
    );
    assert_eq!(
        discovery["executeOperationSearch"]["effectClassExcludedMatches"],
        json!(1)
    );
    assert!(discovery.get("unsupportedOperationCandidate").is_none());
    let excluded = discovery["effectClassExcludedOperationMatches"]
        .as_array()
        .expect("excluded operations");
    assert_eq!(excluded[0]["operation"], "context_policy_snapshot");
    assert_eq!(
        excluded[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
        false
    );
    assert!(
        excluded[0]["exclusionReason"]
            .as_str()
            .expect("exclusion reason")
            .contains("Supported operation exists")
    );
}

#[test]
fn catalog_search_returns_flat_inspect_targets_for_included_and_effect_excluded_matches() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "effectClass": "read_only",
            "limit": 10,
            "text": "question"
        }),
    );

    let targets = discovery["allDiscoveredInspectTargets"]
        .as_array()
        .expect("flat inspect targets");
    let operations = targets
        .iter()
        .filter_map(|target| target["operation"].as_str())
        .collect::<BTreeSet<_>>();
    assert!(operations.contains("question_inspect"));
    assert!(operations.contains("question_create"));
    assert!(operations.contains("question_answer"));

    let inspect = targets
        .iter()
        .find(|target| target["operation"] == "question_inspect")
        .expect("question inspect target");
    assert_eq!(inspect["catalogInspectId"], "execute::question_inspect");
    assert_eq!(
        inspect["inspectArguments"]["id"],
        "execute::question_inspect"
    );
    assert_eq!(inspect["excludedFromImmediateInvocation"], false);
    assert_eq!(inspect["readOnlyInspectionSafe"], true);

    let create = targets
        .iter()
        .find(|target| target["operation"] == "question_create")
        .expect("question create target");
    assert_eq!(create["catalogInspectId"], "execute::question_create");
    assert_eq!(create["inspectArguments"]["id"], "execute::question_create");
    assert_eq!(create["excludedFromImmediateInvocation"], true);
    assert_eq!(create["readOnlyInspectionSafe"], false);
    assert!(
        create["agentGuidance"]
            .as_str()
            .expect("agent guidance")
            .contains("Inspect the schema only")
    );
}

#[test]
fn catalog_search_does_not_suggest_then_invoke_for_write_like_matches() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "limit": 10,
            "text": "context_control_snapshot"
        }),
    );

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    assert_eq!(matches[0]["operation"], "context_control_snapshot");
    assert_eq!(
        matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
        false
    );
    assert_eq!(
        discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
        "execute::context_control_snapshot"
    );
    assert!(
        discovery["agentNextStep"].get("thenInvoke").is_none(),
        "write-like discovery must not emit immediate invoke guidance"
    );
    assert_eq!(
        discovery["agentNextStep"]["thenInvokeBlocked"]["operation"],
        "context_control_snapshot"
    );
}

#[test]
fn catalog_inspect_advertises_context_status_as_read_only_session_state() {
    let discovery = execute_operation_inspect_projection(
        "context_control_status",
        "execute::context_control_status",
    );

    assert_eq!(
        discovery["schema"]["requiredPayloadFields"],
        json!(["operation"])
    );
    assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
    assert!(
        discovery["inputSchema"]["properties"]
            .as_object()
            .expect("input schema properties")
            .get("sessionId")
            .is_none(),
        "model-facing context status schema must rely on trusted current-session scope"
    );
    assert!(
        discovery["modelFacingInvocation"]["arguments"]
            .as_object()
            .expect("model invocation arguments")
            .get("sessionId")
            .is_none()
    );
    assert_eq!(
        discovery["agentUsage"]["effect"]["readOnlyInspectionSafe"],
        true
    );
    assert_eq!(discovery["agentUsage"]["effect"]["mutatesState"], false);
    assert_eq!(
        discovery["agentUsage"]["preflight"]["networkPolicy"],
        "none"
    );
    let guidance = execute_operation_invocation_guidance("context_control_status");
    assert!(guidance.contains("pass only operation"));
    assert!(guidance.contains("Do not include sessionId"));
}

#[test]
fn catalog_search_content_reports_complete_and_effect_excluded_matches() {
    let mut discovery = json!({
        "functions": [],
        "summary": {
            "functions": {
                "visible": 0
            }
        }
    });

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "effectClass": "read_only",
            "limit": 10,
            "text": "context_policy_snapshot"
        }),
    );

    let content = catalog_search_content(&discovery);
    assert!(
        content.contains("Search complete: all 0 matching execute operation(s) returned"),
        "catalog_search content should not leave completeness implicit: {content}"
    );
    assert!(
        content.contains("1 supported operation(s) were excluded by the requested effect class"),
        "catalog_search content should summarize effect-class exclusions: {content}"
    );
    assert!(
        !content.contains("truncated"),
        "complete searches must not be described as truncated: {content}"
    );
}

#[test]
fn catalog_search_adds_prefix_execute_operation_matches() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "capability_binding_request", "limit": 20}),
    );

    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert!(operations.contains(&"capability_binding_request_record"));
    assert!(operations.contains(&"capability_binding_request_list"));
    assert!(operations.contains(&"capability_binding_request_inspect"));
    assert!(
        discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .all(|value| value["matchKind"] == "prefix")
    );
}

#[test]
fn catalog_search_explicitly_recovers_unsupported_operation_like_queries() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "capability_shadow_trial_request_list", "limit": 10}),
    );

    assert_eq!(
        discovery["executeOperationSearch"]["canonicalQuery"],
        "capability_shadow_trial_request_list"
    );
    assert_eq!(
        discovery["executeOperationSearch"]["totalMatches"],
        json!(0)
    );
    assert_eq!(
        discovery["executeOperationMatches"]
            .as_array()
            .expect("empty operation matches")
            .len(),
        0
    );
    assert_eq!(discovery["unsupportedOperationCandidate"], json!(true));
    assert!(
        discovery["unsupportedOperationRecovery"]["guidance"]
            .as_str()
            .expect("guidance")
            .contains("Do not call the queried name")
    );
    let alternatives = discovery["unsupportedOperationRecovery"]["closestReadOnlyAlternatives"]
        .as_array()
        .expect("alternatives");
    assert!(alternatives.iter().any(|alternative| {
        alternative["operation"] == "capability_binding_cockpit_overview"
            && alternative["arguments"]["targetOperation"] == "<supported_operation>"
    }));
    assert!(alternatives.iter().any(|alternative| {
        alternative["operation"] == "capability_shadow_trial_evidence_inspect"
    }));
}

#[test]
fn catalog_search_prioritizes_explicit_unsupported_tokens_in_natural_language() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "effectClass": "pure_read",
            "limit": 10,
            "text": "capability_shadow_trial_request_list provider-visible operation"
        }),
    );

    assert_eq!(discovery["executeOperationSearch"]["totalMatches"], 0);
    assert_eq!(discovery["executeOperationMatches"], json!([]));
    assert_eq!(
        discovery["unsupportedOperationCandidates"],
        json!(["capability_shadow_trial_request_list"])
    );
    assert_eq!(discovery["unsupportedOperationCandidate"], true);
    assert!(
        catalog_search_content(&discovery)
            .contains("Do not invoke or inspect those names as supported operations")
    );
}

#[test]
fn catalog_inspect_returns_recovery_for_explicit_unsupported_execute_id() {
    let candidate = unsupported_execute_operation_inspect_candidate(&json!({
        "kind": "function",
        "id": "execute::capability_shadow_trial_request_list"
    }))
    .expect("unsupported execute candidate");

    assert_eq!(candidate.canonical, "capability_shadow_trial_request_list");
    assert_eq!(
        unsupported_operation_recovery_projection(&candidate)["supportedOperation"],
        false
    );
}

#[test]
fn catalog_search_maps_catalog_style_text_to_execute_operation_match() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(&mut discovery, &json!({"text": "git::status"}));

    let matches = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches");
    assert_eq!(matches[0]["operation"], "git_status");
    assert_eq!(matches[0]["matchKind"], "exact");
    assert_eq!(matches[0]["catalogInspectId"], "execute::git_status");
    assert_eq!(
        matches[0]["schemaInspection"]["arguments"]["id"],
        "execute::git_status"
    );
    assert_eq!(matches[0]["capabilityPool"]["audience"], "session_work");
    assert_eq!(
        matches[0]["capabilityPool"]["replacementClass"],
        "runtime_routable"
    );
    assert_eq!(
        discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
        "execute::git_status"
    );
}

#[test]
fn catalog_search_prioritizes_trace_evidence_plan_for_schema_and_trace_queries() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "text": "git_status trace evidence provider-visible schema",
            "limit": 10
        }),
    );

    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        operations,
        vec!["git_status", "trace_list", "catalog_inspect"]
    );
    assert_eq!(
        discovery["agentSearchPlan"]["purpose"],
        "Deterministic read-only plan for schema inspection and provider-safe trace evidence."
    );
    assert_eq!(
        discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["id"],
        "execute::git_status"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["afterTargetInvocation"]["operation"],
        "trace_list"
    );
    assert_eq!(
        discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
        "execute::git_status"
    );
    assert_eq!(
        discovery["agentNextStep"]["thenInvoke"]["operation"],
        "git_status"
    );
}

#[test]
fn catalog_search_keeps_trace_plan_when_query_names_trace_helpers() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "text": "execute git_status schema read-only current session trace evidence trace_list",
            "limit": 10
        }),
    );

    assert_eq!(
        discovery["agentSearchPlan"]["targetOperation"],
        "git_status"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["id"],
        "execute::git_status"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["afterTargetInvocation"]["arguments"]["operation"],
        "trace_list"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["optionalDetailInspection"]["operation"],
        "trace_get"
    );
    assert!(
        discovery["agentSearchPlan"]["completionRule"]
            .as_str()
            .expect("completion rule")
            .contains("internal audit storage may retain raw fields")
    );
    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert!(!operations.contains(&"trace_get"));
}

#[test]
fn catalog_search_keeps_git_status_primary_for_shadow_trial_recovery_trace_queries() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "text": "supported read-only operations list capability shadow trial request schema git status trace evidence provider safe",
            "limit": 10
        }),
    );

    assert_eq!(
        discovery["agentSearchPlan"]["purpose"],
        "Deterministic read-only plan for schema inspection and provider-safe trace evidence."
    );
    assert_eq!(
        discovery["agentSearchPlan"]["targetOperation"],
        "git_status"
    );
    assert_eq!(
        discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
        "execute::git_status"
    );
    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        operations,
        vec!["git_status", "trace_list", "catalog_inspect"]
    );
}

#[test]
fn catalog_search_does_not_create_trace_plan_for_mutating_targets() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "text": "capability_shadow_trial_request_record trace evidence schema",
            "limit": 10
        }),
    );

    assert!(
        discovery.get("agentSearchPlan").is_none(),
        "mutating operations must not be recommended as read-only trace evidence targets: {discovery}"
    );
}

#[test]
fn catalog_search_returns_agent_readiness_plan_for_multi_intent_queries() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "text": "git_status replacement readiness shadow trial route binding evidence",
            "limit": 25
        }),
    );

    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    for expected in [
        "capability_binding_cockpit_overview",
        "capability_replacement_candidate_list",
        "capability_route_binding_list",
        "capability_route_event_list",
    ] {
        assert!(
            operations.contains(&expected),
            "multi-intent search should include {expected}: {operations:?}"
        );
    }
    assert!(
        !operations.contains(&"git_status"),
        "target adapter invocation is not readiness evidence and must stay conditional"
    );
    assert!(
        !operations.contains(&"catalog_inspect"),
        "schema inspection is not readiness evidence and must stay conditional"
    );
    assert!(
        !operations.contains(&"capability_shadow_trial_evidence_inspect"),
        "evidence inspect needs an exact evidence id and must not appear as an immediately actionable match"
    );
    assert!(
        discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .all(|value| value["matchKind"] == "plan")
    );
    assert!(!operations.contains(&"git_commit"));
    assert!(!operations.contains(&"capability_shadow_trial_request_record"));
    assert_eq!(
        discovery["agentSearchPlan"]["targetOperation"],
        json!("git_status")
    );
    assert_eq!(
        discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["targetOperation"],
        json!("git_status")
    );
    let readiness_sequence = discovery["agentSearchPlan"]["readOnlySequence"]
        .as_array()
        .expect("read-only readiness sequence");
    assert!(
        readiness_sequence
            .iter()
            .all(|entry| entry["operation"] != "catalog_inspect"),
        "replacement readiness must not treat adapter schema inspection as evidence"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["adapterInvocationSchemaInspection"]["arguments"]["id"],
        "execute::git_status"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["adapterInvocationSchemaInspection"]["notPartOfReadinessCompletion"],
        json!(true)
    );
    assert!(
        discovery["agentSearchPlan"]["adapterInvocationSchemaInspection"]["useOnlyWhen"]
            .as_str()
            .expect("adapter schema guidance")
            .contains("explicitly needs to invoke")
    );
    assert!(
        discovery["agentSearchPlan"]["completionRule"]
            .as_str()
            .expect("completion rule")
            .contains("stop and report")
    );
    assert_eq!(
        discovery["agentSearchPlan"]["terminalZeroEvidencePath"]["state"],
        "answer_now_no_current_scope_evidence"
    );
    assert!(
        discovery["agentSearchPlan"]["terminalZeroEvidencePath"]["answerGuidance"]
            .as_str()
            .expect("zero evidence answer guidance")
            .contains("Do not inspect evidence schemas")
    );
    assert!(
        discovery["agentSearchPlan"]["finalAnswerWhen"]
            .as_str()
            .expect("final answer")
            .contains("stop and answer")
    );
    assert_eq!(
        discovery["agentSearchPlan"]["evidenceInspectAvailability"]["callableNow"],
        json!(false)
    );
    assert_eq!(
        discovery["agentSearchPlan"]["evidenceInspectAvailability"]["doNotInspectSchemasFromSearch"],
        json!(true)
    );
    assert_eq!(
        discovery["agentSearchPlan"]["doNotInspect"][0]["operation"],
        "evidence inspection"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["doNotInspect"][1]["operation"],
        "evidence schema inspection"
    );
    let do_not_call = discovery["agentSearchPlan"]["doNotCall"]
        .as_array()
        .expect("do not call");
    assert!(
        do_not_call
            .iter()
            .any(|entry| entry["operation"] == "git_status")
    );
    assert!(
        do_not_call
            .iter()
            .any(|entry| entry["operation"] == "capability_shadow_trial_request_list")
    );
    assert_eq!(
        discovery["agentNextStep"]["priority"],
        "follow_agent_search_plan_primary_inspection"
    );
    assert_eq!(
        discovery["agentNextStep"]["primaryInspection"]["operation"],
        "capability_binding_cockpit_overview"
    );
    let contextual_write_operations = discovery["agentSearchPlan"]["contextualWriteOperations"]
        .as_array()
        .expect("contextual write operations");
    let contextual_names = contextual_write_operations
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        contextual_names,
        vec![
            "capability_shadow_trial_request_record",
            "capability_shadow_trial_decision_record",
            "capability_shadow_trial_run_record",
        ]
    );
    assert!(
        contextual_write_operations
            .iter()
            .all(|value| value["readOnlyInspectionSafe"] == false)
    );
    assert!(
        contextual_write_operations[0]["requiredPayloadFields"]
            .as_array()
            .expect("shadow request required fields")
            .iter()
            .any(|field| field.as_str() == Some("currentBuiltInOwner"))
    );
    assert!(
        contextual_write_operations[0]["agentUsage"]["preflight"]["requiredPayloadFields"]
            .as_array()
            .expect("shadow request preflight fields")
            .iter()
            .any(|field| field.as_str() == Some("currentBuiltInOwner"))
    );
    assert!(contextual_write_operations.iter().all(|value| {
        value["schemaInspection"]["arguments"]["id"]
            .as_str()
            .expect("schema inspection id")
            .starts_with("execute::capability_shadow_trial_")
    }));
}

#[test]
fn catalog_search_returns_module_governance_read_only_plan_for_broad_queries() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({
            "text": "module governance registry lifecycle runtime dependency request decision policy replacement binding route read-only list inspect",
            "effectClass": "pure_read",
            "limit": 50
        }),
    );

    assert_eq!(
        discovery["agentSearchPlan"]["purpose"],
        "Deterministic read-only plan for broad module-governance discovery and readiness checks."
    );
    assert_eq!(
        discovery["agentNextStep"]["priority"],
        "follow_module_governance_read_only_plan"
    );
    assert_eq!(
        discovery["agentSearchPlan"]["schemaPolicy"]["doNotInspectEverySibling"],
        json!(true)
    );
    assert!(
        discovery["agentSearchPlan"]["schemaPolicy"]["reason"]
            .as_str()
            .expect("schema policy reason")
            .contains("Per-operation schema fan-out is unnecessary")
    );
    let operations = discovery["executeOperationMatches"]
        .as_array()
        .expect("operation matches")
        .iter()
        .filter_map(|value| value["operation"].as_str())
        .collect::<Vec<_>>();
    for expected in [
        "module_list",
        "module_lifecycle_list",
        "module_runtime_list",
        "module_dependency_request_list",
        "module_dependency_decision_list",
        "module_dependency_policy_list",
        "capability_binding_cockpit_overview",
        "capability_binding_request_list",
        "capability_binding_decision_list",
        "capability_binding_policy_list",
        "capability_replacement_candidate_list",
        "capability_route_binding_list",
        "capability_route_event_list",
    ] {
        assert!(
            operations.contains(&expected),
            "broad governance plan should include {expected}: {operations:?}"
        );
    }
    assert!(
        operations
            .iter()
            .all(|operation| operation.ends_with("_list")
                || *operation == "capability_binding_cockpit_overview"),
        "broad governance plan must expose only overview/list operations: {operations:?}"
    );
    assert!(!operations.contains(&"module_lifecycle_request"));
    assert!(!operations.contains(&"module_runtime_request"));
    assert!(!operations.contains(&"module_dependency_request_record"));
    assert!(!operations.contains(&"capability_route_activate"));
    assert!(
        discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .all(|value| value["agentUsage"]["effect"]["readOnlyInspectionSafe"] == true)
    );
    let sequence = discovery["agentSearchPlan"]["readOnlySequence"]
        .as_array()
        .expect("read-only sequence");
    assert_eq!(sequence.len(), operations.len());
    assert!(sequence.iter().all(|entry| {
        entry["arguments"]["operation"]
            .as_str()
            .is_some_and(|operation| operations.contains(&operation))
    }));
    assert_eq!(
        sequence
            .iter()
            .find(|entry| entry["operation"] == "capability_binding_cockpit_overview")
            .expect("cockpit overview step")["arguments"],
        json!({"operation": "capability_binding_cockpit_overview"})
    );
    assert!(
        discovery["agentSearchPlan"]["completionRule"]
            .as_str()
            .expect("completion rule")
            .contains("call trace_list last")
    );
    assert!(
        discovery["agentSearchPlan"]["traceEvidenceBoundary"]
            .as_str()
            .expect("trace evidence boundary")
            .contains("point-in-time projection")
    );
    assert!(
        discovery["agentSearchPlan"]["traceEvidenceBoundary"]
            .as_str()
            .expect("trace evidence boundary")
            .contains("call trace_list again at the end")
    );
    assert!(
        discovery["agentSearchPlan"]["finalAnswerGuidance"]
            .as_str()
            .expect("final answer guidance")
            .contains("provider transcript tool-call ids may be visible")
    );
    assert!(
        discovery["agentSearchPlan"]["finalAnswerGuidance"]
            .as_str()
            .expect("final answer guidance")
            .contains("do not report transcript call ids as absent")
    );
    assert!(
        discovery["agentSearchPlan"]["completionRule"]
            .as_str()
            .expect("completion rule")
            .contains("no provider-visible mutating capability operation")
    );
    assert!(
        discovery["agentSearchPlan"]["completionRule"]
            .as_str()
            .expect("completion rule")
            .contains("Empty lists are valid evidence")
    );
}

#[test]
fn catalog_search_does_not_expand_generic_execute_catalog_function() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "capability::execute", "limit": 50}),
    );

    assert!(
        discovery.get("executeOperationMatches").is_none(),
        "generic capability::execute schema must not become operation matches"
    );
    assert!(discovery.get("executeOperationSearch").is_none());
}

#[test]
fn catalog_search_does_not_expand_normalized_generic_execute_query() {
    let mut discovery = json!({"functions": []});

    annotate_execute_operation_matches(
        &mut discovery,
        &json!({"text": "capability_execute", "limit": 50}),
    );

    assert!(
        discovery.get("executeOperationMatches").is_none(),
        "normalized generic execute query must not become operation matches"
    );
    assert!(discovery.get("executeOperationSearch").is_none());
}

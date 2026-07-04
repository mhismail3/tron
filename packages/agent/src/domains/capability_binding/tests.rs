use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    activate_capability_binding_policy_value_at, inspect_capability_binding_policy_value,
    inspect_capability_binding_request_value, list_capability_binding_decision_value,
    list_capability_binding_policy_value, list_capability_binding_request_value,
    record_capability_binding_decision_value_at, record_capability_binding_request_value_at,
};
use super::validation::{
    CAPABILITY_BINDING_POLICY_VERSION, CAPABILITY_MODULARITY_INVENTORY_VERSION,
};
use super::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_DECISION_SCHEMA_ID,
    CAPABILITY_BINDING_POLICY_KIND, CAPABILITY_BINDING_POLICY_SCHEMA_ID,
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_BINDING_REQUEST_SCHEMA_ID, Deps,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, DeriveGrant,
    EngineResourceVersioningMode, FunctionId, Invocation, InvocationId, RiskLevel, TraceId,
    builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-27T12:00:00Z";

struct Fixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[
                CAPABILITY_BINDING_REQUEST_KIND,
                CAPABILITY_BINDING_DECISION_KIND,
                CAPABILITY_BINDING_POLICY_KIND,
            ],
            &[
                "kind:capability_binding_request",
                "kind:capability_binding_decision",
                "kind:capability_binding_policy",
            ],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[
                CAPABILITY_BINDING_REQUEST_KIND,
                CAPABILITY_BINDING_DECISION_KIND,
                CAPABILITY_BINDING_POLICY_KIND,
            ],
            &[
                "kind:capability_binding_request",
                "kind:capability_binding_decision",
                "kind:capability_binding_policy",
            ],
            "none",
        )
        .await;
        Self {
            deps,
            session_id,
            write_grant_id,
            read_grant_id,
        }
    }

    async fn binding_request(&self, key: &str) -> Value {
        let invocation = self.write_invocation(key, request_payload(key));
        record_capability_binding_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record binding request")
    }

    async fn binding_decision(&self, key: &str, request: &Value, decision: &str) -> Value {
        let request_id = request["capabilityBindingRequestResourceId"]
            .as_str()
            .expect("request id");
        let request_version_id = request["capabilityBindingRequestVersionId"]
            .as_str()
            .expect("request version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-request-exact"), request_id)
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityBindingRequestResourceId": request_id,
                "expectedCapabilityBindingRequestVersionId": request_version_id,
                "capabilityBindingDecisionId": format!("{key}-decision"),
                "decision": decision,
                "reason": "Binding governance recorded a metadata-only policy decision.",
                "denialEvidence": [{"kind": "evidence", "resourceId": "evidence:denial", "role": "denial"}]
            }),
            grant_id,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        );
        record_capability_binding_decision_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record binding decision")
    }

    async fn binding_policy(&self, key: &str, decision: &Value) -> Value {
        let decision_id = decision["capabilityBindingDecisionResourceId"]
            .as_str()
            .expect("decision id");
        let decision_version_id = decision["capabilityBindingDecisionVersionId"]
            .as_str()
            .expect("decision version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-decision-exact"), decision_id)
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityBindingDecisionResourceId": decision_id,
                "expectedCapabilityBindingDecisionVersionId": decision_version_id,
                "capabilityBindingPolicyId": format!("{key}-policy"),
                "reason": "Activate approved metadata binding policy without routing changes."
            }),
            grant_id,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        );
        activate_capability_binding_policy_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("activate binding policy")
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[
                CAPABILITY_BINDING_REQUEST_KIND,
                CAPABILITY_BINDING_DECISION_KIND,
                CAPABILITY_BINDING_POLICY_KIND,
            ],
            &[
                "kind:capability_binding_request",
                "kind:capability_binding_decision",
                "kind:capability_binding_policy",
                exact_selector.as_str(),
            ],
            "none",
        )
        .await
    }

    async fn exact_write_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[
                CAPABILITY_BINDING_REQUEST_KIND,
                CAPABILITY_BINDING_DECISION_KIND,
                CAPABILITY_BINDING_POLICY_KIND,
            ],
            &[
                "kind:capability_binding_request",
                "kind:capability_binding_decision",
                "kind:capability_binding_policy",
                exact_selector.as_str(),
            ],
            "none",
        )
        .await
    }

    fn write_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.write_grant_id.clone(),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        )
    }

    fn read_invocation(&self, key: &str, payload: Value) -> Invocation {
        invocation(
            key,
            payload,
            self.read_grant_id.clone(),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &self.session_id,
        )
    }
}

#[test]
fn capability_binding_resource_types_are_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    for (kind, schema_id) in [
        (
            CAPABILITY_BINDING_REQUEST_KIND,
            CAPABILITY_BINDING_REQUEST_SCHEMA_ID,
        ),
        (
            CAPABILITY_BINDING_DECISION_KIND,
            CAPABILITY_BINDING_DECISION_SCHEMA_ID,
        ),
        (
            CAPABILITY_BINDING_POLICY_KIND,
            CAPABILITY_BINDING_POLICY_SCHEMA_ID,
        ),
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.kind == kind)
            .expect("capability binding definition");
        assert_eq!(definition.schema_id, schema_id);
        assert_eq!(
            definition.versioning_mode,
            EngineResourceVersioningMode::AppendOnly
        );
        assert_eq!(
            definition.required_capabilities["read"],
            json!([READ_SCOPE, RESOURCE_READ_SCOPE])
        );
        assert_eq!(
            definition.required_capabilities["write"],
            json!([WRITE_SCOPE, RESOURCE_WRITE_SCOPE])
        );
        assert_eq!(
            definition.materialization_rules["networkPolicy"],
            json!("none")
        );
        assert_eq!(
            definition.materialization_rules["runtimeRouting"],
            json!("forbidden_in_this_slice")
        );
        assert_eq!(
            definition.materialization_rules["hotSwap"],
            json!("forbidden")
        );
        assert_eq!(
            definition.materialization_rules["packageManager"],
            json!("forbidden")
        );
        assert!(
            definition.redaction_rules["neverReturn"]
                .as_array()
                .expect("redaction list")
                .contains(&json!("rawAuthorityId"))
        );
    }
}

#[tokio::test]
async fn request_decision_policy_record_list_inspect_and_replay_are_metadata_only() {
    let fixture = Fixture::new("capability-binding-flow").await;
    let request = fixture.binding_request("request").await;
    assert_eq!(request["status"], json!("pending_review"));
    assert_eq!(request["idempotentReplay"], json!(false));
    assert_eq!(
        request["bindingRequest"]["operation"]["dispatchChanged"],
        json!(false)
    );
    assert_eq!(
        request["bindingRequest"]["binding"]["runtimeRoutingEnabled"],
        json!(false)
    );
    let replay = fixture.binding_request("request").await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    let request_id = request["capabilityBindingRequestResourceId"]
        .as_str()
        .expect("request id");

    let decision = fixture
        .binding_decision("decision", &request, "approved")
        .await;
    assert_eq!(decision["status"], json!("approved_policy"));
    assert_eq!(
        decision["bindingDecision"]["policyCandidate"]["routingEnabled"],
        json!(false)
    );

    let policy = fixture.binding_policy("policy", &decision).await;
    assert_eq!(policy["status"], json!("active"));
    assert_eq!(
        policy["bindingPolicy"]["activation"]["runtimeRoutingEnabled"],
        json!(false)
    );
    let policy_id = policy["capabilityBindingPolicyResourceId"]
        .as_str()
        .expect("policy id");

    assert_eq!(
        list_capability_binding_request_value(
            &fixture.deps,
            &fixture.read_invocation("list-requests", json!({})),
            &json!({})
        )
        .await
        .expect("list requests")["bindingRequests"]
            .as_array()
            .expect("binding requests")
            .len(),
        1
    );
    assert_eq!(
        list_capability_binding_decision_value(
            &fixture.deps,
            &fixture.read_invocation("list-decisions", json!({})),
            &json!({})
        )
        .await
        .expect("list decisions")["bindingDecisions"]
            .as_array()
            .expect("binding decisions")
            .len(),
        1
    );
    assert_eq!(
        list_capability_binding_policy_value(
            &fixture.deps,
            &fixture.read_invocation("list-policies", json!({})),
            &json!({})
        )
        .await
        .expect("list policies")["bindingPolicies"]
            .as_array()
            .expect("binding policies")
            .len(),
        1
    );

    let request_grant = fixture.exact_read_grant("request-exact", request_id).await;
    let inspected_request = inspect_capability_binding_request_value(
        &fixture.deps,
        &invocation(
            "inspect-request",
            json!({"capabilityBindingRequestResourceId": request_id}),
            request_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"capabilityBindingRequestResourceId": request_id}),
    )
    .await
    .expect("inspect request");
    assert_eq!(
        inspected_request["bindingRequest"]["bindingRequest"]["sideEffectProof"]["networkPolicy"],
        json!("none")
    );
    assert_eq!(
        inspected_request["bindingRequest"]["bindingRequest"]["sideEffectProof"]["dispatchTableMutated"],
        json!(false)
    );
    assert_eq!(
        inspected_request["bindingRequest"]["projection"]["agentStateInherited"],
        json!(false)
    );
    assert!(
        inspected_request["history"]["resourceEvents"]
            .as_u64()
            .expect("history events")
            >= 1
    );

    let policy_grant = fixture.exact_read_grant("policy-exact", policy_id).await;
    let inspected_policy = inspect_capability_binding_policy_value(
        &fixture.deps,
        &invocation(
            "inspect-policy",
            json!({"capabilityBindingPolicyResourceId": policy_id}),
            policy_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"capabilityBindingPolicyResourceId": policy_id}),
    )
    .await
    .expect("inspect policy");
    assert_eq!(
        inspected_policy["bindingPolicy"]["bindingPolicy"]["activation"]["hotSwapPerformed"],
        json!(false)
    );
    assert_eq!(
        inspected_policy["bindingPolicy"]["bindingPolicy"]["sideEffectProof"]["moduleExecuted"],
        json!(false)
    );
}

#[tokio::test]
async fn authoritative_target_metadata_rejects_spoofed_locked_replacement() {
    let fixture = Fixture::new("capability-binding-locked-spoof").await;

    let mut kernel_spoof = request_payload("kernel-spoof");
    kernel_spoof["targetOperation"] = json!("observe");
    kernel_spoof["currentBuiltInOwner"] = json!("domains::capability::operations::common");
    kernel_spoof["ownershipClass"] = json!("adapter_replaceable");
    kernel_spoof["replacementTarget"] = json!("future_git_adapter");
    kernel_spoof["bindingMode"] = json!("replace");
    let invocation = fixture.write_invocation("kernel-spoof", kernel_spoof);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("kernel spoof rejected")
    .to_string();
    assert!(
        error.contains("ownershipClass mismatch for observe: expected kernel_locked"),
        "{error}"
    );

    let mut governance_spoof = request_payload("governance-spoof");
    governance_spoof["targetOperation"] = json!("notification_send");
    governance_spoof["currentBuiltInOwner"] =
        json!("domains::capability::operations::notifications + domains::notifications");
    governance_spoof["ownershipClass"] = json!("adapter_replaceable");
    governance_spoof["replacementTarget"] = json!("future_git_adapter");
    governance_spoof["bindingMode"] = json!("replace");
    let invocation = fixture.write_invocation("governance-spoof", governance_spoof);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("governance spoof rejected")
    .to_string();
    assert!(
        error.contains("ownershipClass mismatch for notification_send: expected governance_locked"),
        "{error}"
    );
}

#[tokio::test]
async fn authoritative_locked_classes_cannot_request_replacement() {
    let fixture = Fixture::new("capability-binding-locked-authoritative").await;
    for (key, target_operation, current_owner, ownership_class, replacement_target) in [
        (
            "kernel-locked",
            "observe",
            "domains::capability::operations::common",
            "kernel_locked",
            "kernel_diagnostic_stays_engine_owned",
        ),
        (
            "governance-locked",
            "notification_send",
            "domains::capability::operations::notifications + domains::notifications",
            "governance_locked",
            "delivery_policy_stays_server_governed_until_push_transport_policy_exists",
        ),
    ] {
        let mut payload = request_payload(key);
        payload["targetOperation"] = json!(target_operation);
        payload["currentBuiltInOwner"] = json!(current_owner);
        payload["ownershipClass"] = json!(ownership_class);
        payload["replacementTarget"] = json!(replacement_target);
        payload["bindingMode"] = json!("replace");
        let invocation = fixture.write_invocation(key, payload);
        let error = record_capability_binding_request_value_at(
            &fixture.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("locked replacement rejected")
        .to_string();
        assert!(error.contains("cannot request replacement"), "{error}");
    }
}

#[tokio::test]
async fn adapter_and_module_owned_replacement_paths_require_rollback_metadata() {
    let fixture = Fixture::new("capability-binding-allowed").await;
    let adapter_request = fixture.binding_request("adapter-replace").await;
    assert_eq!(
        adapter_request["bindingRequest"]["operation"]["ownershipClass"],
        json!("adapter_replaceable")
    );
    assert_eq!(
        adapter_request["bindingRequest"]["binding"]["mode"],
        json!("replace")
    );

    let mut module_payload = request_payload("module-owned");
    module_payload["targetOperation"] = json!("module_program_execution_start");
    module_payload["currentBuiltInOwner"] = json!(
        "domains::capability::operations::module_program_execution + module_program_execution pack"
    );
    module_payload["ownershipClass"] = json!("module_owned");
    module_payload["replacementTarget"] =
        json!("already_module_owned_template_for_supervised_replacement");
    let invocation = fixture.write_invocation("module-owned", module_payload);
    let module_request = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("module owned replace request accepted as metadata");
    assert_eq!(
        module_request["bindingRequest"]["operation"]["ownershipClass"],
        json!("module_owned")
    );
    assert_eq!(
        module_request["bindingRequest"]["binding"]["runtimeRoutingEnabled"],
        json!(false)
    );

    let mut missing_rollback = request_payload("missing-rollback");
    missing_rollback["rollbackRef"] = Value::Null;
    let invocation = fixture.write_invocation("missing-rollback", missing_rollback);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("rollback ref required")
    .to_string();
    assert!(error.contains("rollbackRef"), "{error}");
}

#[tokio::test]
async fn unknown_target_and_owner_or_target_mismatches_are_rejected() {
    let fixture = Fixture::new("capability-binding-authoritative-mismatch").await;

    let mut unknown = request_payload("unknown-target");
    unknown["targetOperation"] = json!("future_unknown_operation");
    let invocation = fixture.write_invocation("unknown-target", unknown);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("unknown target rejected")
    .to_string();
    assert!(
        error.contains("unknown targetOperation future_unknown_operation"),
        "{error}"
    );

    let mut owner_mismatch = request_payload("owner-mismatch");
    owner_mismatch["currentBuiltInOwner"] = json!("domains::capability::operations::common");
    let invocation = fixture.write_invocation("owner-mismatch", owner_mismatch);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("owner mismatch rejected")
    .to_string();
    assert!(
        error.contains("currentBuiltInOwner mismatch for git_status"),
        "{error}"
    );

    let mut target_mismatch = request_payload("target-mismatch");
    target_mismatch["replacementTarget"] = json!("different_future_adapter");
    let invocation = fixture.write_invocation("target-mismatch", target_mismatch);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("replacement target mismatch rejected")
    .to_string();
    assert!(
        error.contains("replacementTarget mismatch for git_status"),
        "{error}"
    );
}

#[tokio::test]
async fn stale_guards_exact_selectors_and_wildcards_are_rejected() {
    let fixture = Fixture::new("capability-binding-guards").await;

    let mut stale_inventory = request_payload("stale-inventory");
    stale_inventory["staleVersionGuard"]["expectedInventoryVersion"] = json!("old-inventory");
    let stale_inventory_invocation = fixture.write_invocation("stale-inventory", stale_inventory);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &stale_inventory_invocation,
        &stale_inventory_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("stale inventory rejected")
    .to_string();
    assert!(
        error.contains("stale capability modularity inventory"),
        "{error}"
    );

    let mut bad_network = request_payload("bad-network");
    bad_network["authorityConstraints"]["networkPolicy"] = json!("allowed");
    let bad_network_invocation = fixture.write_invocation("bad-network", bad_network);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &bad_network_invocation,
        &bad_network_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("network policy rejected")
    .to_string();
    assert!(error.contains("networkPolicy none"), "{error}");

    let mut wildcard_selector = request_payload("wildcard-selector");
    wildcard_selector["authorityConstraints"]["resourceSelectors"] = json!(["kind:*"]);
    let wildcard_selector_invocation =
        fixture.write_invocation("wildcard-selector", wildcard_selector);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &wildcard_selector_invocation,
        &wildcard_selector_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wildcard selector rejected")
    .to_string();
    assert!(error.contains("wildcard resource selectors"), "{error}");

    let wildcard_grant_id = derive_grant(
        &fixture.deps,
        "wildcard-wide",
        &["*"],
        &["*"],
        &["*"],
        "none",
    )
    .await;
    let wildcard_invocation = invocation(
        "wildcard-wide",
        request_payload("wildcard-wide"),
        wildcard_grant_id,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wildcard grants rejected")
    .to_string();
    assert!(error.contains("wildcard grants"), "{error}");

    let request = fixture.binding_request("selector-source").await;
    let request_id = request["capabilityBindingRequestResourceId"]
        .as_str()
        .expect("request id");
    let selector_denied = inspect_capability_binding_request_value(
        &fixture.deps,
        &fixture.read_invocation(
            "selector-denied",
            json!({"capabilityBindingRequestResourceId": request_id}),
        ),
        &json!({"capabilityBindingRequestResourceId": request_id}),
    )
    .await
    .expect_err("exact selector required")
    .to_string();
    assert!(
        selector_denied.contains("exact resource:"),
        "{selector_denied}"
    );
}

#[tokio::test]
async fn stale_decision_inputs_and_rejected_decisions_require_evidence() {
    let fixture = Fixture::new("capability-binding-stale-decisions").await;
    let request = fixture.binding_request("request").await;
    let request_id = request["capabilityBindingRequestResourceId"]
        .as_str()
        .expect("request id");
    let request_grant = fixture
        .exact_write_grant("stale-request-exact", request_id)
        .await;

    let stale_request = invocation(
        "stale-request",
        json!({
            "capabilityBindingRequestResourceId": request_id,
            "expectedCapabilityBindingRequestVersionId": "old-version",
            "capabilityBindingDecisionId": "stale-request-decision",
            "decision": "approved",
            "reason": "Decision should fail against stale request version."
        }),
        request_grant.clone(),
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_capability_binding_decision_value_at(
        &fixture.deps,
        &stale_request,
        &stale_request.payload,
        default_operation_at(),
    )
    .await
    .expect_err("stale request rejected")
    .to_string();
    assert!(
        error.contains("stale capability binding request"),
        "{error}"
    );

    let missing_denial = invocation(
        "missing-denial",
        json!({
            "capabilityBindingRequestResourceId": request_id,
            "expectedCapabilityBindingRequestVersionId": request["capabilityBindingRequestVersionId"],
            "capabilityBindingDecisionId": "missing-denial",
            "decision": "rejected",
            "reason": "Rejected metadata policy requires evidence refs."
        }),
        request_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_capability_binding_decision_value_at(
        &fixture.deps,
        &missing_denial,
        &missing_denial.payload,
        default_operation_at(),
    )
    .await
    .expect_err("denial evidence required")
    .to_string();
    assert!(error.contains("denialEvidence"), "{error}");

    let decision = fixture
        .binding_decision("decision-for-stale-policy", &request, "approved")
        .await;
    let decision_id = decision["capabilityBindingDecisionResourceId"]
        .as_str()
        .expect("decision id");
    let decision_grant = fixture
        .exact_write_grant("stale-policy-exact", decision_id)
        .await;
    let stale_policy = invocation(
        "stale-policy",
        json!({
            "capabilityBindingDecisionResourceId": decision_id,
            "expectedCapabilityBindingDecisionVersionId": "old-version",
            "capabilityBindingPolicyId": "stale-policy",
            "reason": "Activation should fail against stale decision version."
        }),
        decision_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = activate_capability_binding_policy_value_at(
        &fixture.deps,
        &stale_policy,
        &stale_policy.payload,
        default_operation_at(),
    )
    .await
    .expect_err("stale decision rejected")
    .to_string();
    assert!(
        error.contains("stale capability binding decision"),
        "{error}"
    );
}

#[tokio::test]
async fn unsafe_payload_material_is_rejected() {
    let fixture = Fixture::new("capability-binding-unsafe").await;
    for payload in [
        {
            let mut payload = request_payload("raw-command");
            payload["command"] = json!("cargo add hypothetical-package");
            payload
        },
        {
            let mut payload = request_payload("debug-payload");
            payload["debugPayload"] = json!({"rawGrantId": "grant-redacted"});
            payload
        },
        {
            let mut payload = request_payload("local-path");
            payload["rationale"] = json!("Read /private/tmp/project manifest directly");
            payload
        },
    ] {
        let invocation = fixture.write_invocation("unsafe", payload);
        let error = record_capability_binding_request_value_at(
            &fixture.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect_err("unsafe payload rejected")
        .to_string();
        assert!(
            error.contains("not accepted")
                || error.contains("path-like")
                || error.contains("credential-like"),
            "unexpected error: {error}"
        );
    }
}

async fn derive_grant(
    deps: &Deps,
    label: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    resource_selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    deps.engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("capability-binding-{label}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").expect("parent grant"),
            subject_actor_id: Some(ActorId::new(format!("actor:{label}")).expect("actor id")),
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
            allowed_resource_kinds: resource_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect(),
            resource_selectors: resource_selectors
                .iter()
                .map(|selector| (*selector).to_owned())
                .collect(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: network_policy.to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "capability_binding_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"test": label}),
            trace_id: TraceId::new(format!("trace-capability-binding-{label}")).expect("trace id"),
        })
        .await
        .expect("derive grant")
        .grant_id
}

fn request_payload(key: &str) -> Value {
    json!({
        "capabilityBindingRequestId": format!("{key}-binding-request"),
        "title": "Capability binding policy request",
        "targetOperation": "git_status",
        "currentBuiltInOwner": "domains::capability::operations::git + domains::git",
        "replacementTarget": "future_module_may_shadow_then_replace_after_exact_git_binding_policy",
        "ownershipClass": "adapter_replaceable",
        "bindingMode": "replace",
        "targetRef": {
            "kind": "module_manifest",
            "resourceId": "module_manifest:future_git_adapter",
            "role": "target"
        },
        "actorScope": "session",
        "rationale": "Governance records metadata for a future adapter proposal without changing dispatch.",
        "contractEvidenceRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:capability_contract",
            "role": "contract"
        }],
        "evidenceRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:scorecard_row",
            "role": "scorecard"
        }],
        "evidenceRequirements": "Provider safe contract and scorecard evidence must exist before any later routing work.",
        "authorityConstraints": {
            "networkPolicy": "none",
            "authorityScopes": ["capability.execute", "git.read", "resource.read"],
            "resourceKinds": ["git_index_change"],
            "resourceSelectors": ["kind:git_index_change"]
        },
        "staleVersionGuard": {
            "expectedInventoryVersion": CAPABILITY_MODULARITY_INVENTORY_VERSION,
            "expectedPolicyVersion": CAPABILITY_BINDING_POLICY_VERSION
        },
        "rollbackRef": {
            "kind": "evidence",
            "resourceId": "evidence:rollback_plan",
            "role": "rollback"
        },
        "disableRef": {
            "kind": "evidence",
            "resourceId": "evidence:disable_plan",
            "role": "disable"
        },
        "auditRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:audit_event",
            "role": "audit"
        }]
    })
}

fn invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    scopes: &[&str],
    session_id: &str,
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new(format!("actor:{key}")).expect("actor id"),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-{key}")).expect("trace id"),
    )
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(format!("idempotency-{key}"));
    for scope in scopes {
        context = context.with_scope((*scope).to_owned());
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).expect("invocation id"),
        function_id: FunctionId::new("capability::execute").expect("function id"),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

fn default_operation_at() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(DEFAULT_OPERATION_AT)
        .expect("valid timestamp")
        .with_timezone(&Utc)
}

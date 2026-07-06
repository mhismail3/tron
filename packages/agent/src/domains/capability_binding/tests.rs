use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::resource_store::current_payload;
use super::route::{
    ActiveRoute, activate_route_value_at, active_route_for_git_status, disable_route_value_at,
    execute_routed_git_status, inspect_replacement_candidate_value, inspect_route_binding_value,
    inspect_route_event_value, list_route_event_value, record_replacement_candidate_value_at,
    record_route_binding_value_at, rollback_route_value_at,
};
use super::service::{
    activate_capability_binding_policy_value_at, cockpit_overview_value,
    inspect_capability_binding_policy_value, inspect_capability_binding_request_value,
    list_capability_binding_decision_value, list_capability_binding_policy_value,
    list_capability_binding_request_value, record_capability_binding_decision_value_at,
    record_capability_binding_request_value_at,
};
use super::shadow_trial::{
    inspect_capability_shadow_trial_evidence_value,
    record_capability_shadow_trial_decision_value_at,
    record_capability_shadow_trial_request_value_at, record_capability_shadow_trial_run_value_at,
};
use super::validation::{
    CAPABILITY_BINDING_POLICY_VERSION, CAPABILITY_MODULARITY_INVENTORY_VERSION,
};
use super::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_DECISION_SCHEMA_ID,
    CAPABILITY_BINDING_POLICY_KIND, CAPABILITY_BINDING_POLICY_SCHEMA_ID,
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_BINDING_REQUEST_SCHEMA_ID,
    CAPABILITY_REPLACEMENT_CANDIDATE_KIND, CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
    CAPABILITY_ROUTE_ACTIVATION_KIND, CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
    CAPABILITY_ROUTE_BINDING_KIND, CAPABILITY_ROUTE_BINDING_SCHEMA_ID, CAPABILITY_ROUTE_EVENT_KIND,
    CAPABILITY_ROUTE_EVENT_SCHEMA_ID, CAPABILITY_ROUTE_ROLLBACK_KIND,
    CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
    CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
    CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID, CAPABILITY_SHADOW_TRIAL_RUN_KIND,
    CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID, Deps,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeliveryMode, DeriveGrant,
    EngineResourceLocation, EngineResourceScope, EngineResourceVersioningMode, FunctionId,
    Invocation, InvocationId, ListResources, MODULE_LIFECYCLE_STATE_KIND,
    MODULE_LIFECYCLE_STATE_SCHEMA_ID, MODULE_RUNTIME_STATE_KIND, MODULE_RUNTIME_STATE_SCHEMA_ID,
    RiskLevel, TraceId, UpdateResource, WorkerId, builtin_resource_type_definitions,
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

struct ShadowFixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl ShadowFixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let write_kinds = shadow_trial_kinds();
        let write_selectors = shadow_trial_kind_selectors();
        let write_selector_refs = write_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-shadow-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &write_kinds,
            &write_selector_refs,
            "none",
        )
        .await;
        let read_kinds = shadow_trial_kinds();
        let read_selectors = shadow_trial_kind_selectors();
        let read_selector_refs = read_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-shadow-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &read_kinds,
            &read_selector_refs,
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

    async fn shadow_request(&self, key: &str) -> Value {
        let invocation = self.write_invocation(key, shadow_request_payload(key));
        record_capability_shadow_trial_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record shadow request")
    }

    async fn shadow_decision(&self, key: &str, request: &Value, decision: &str) -> Value {
        let request_id = request["capabilityShadowTrialRequestResourceId"]
            .as_str()
            .expect("shadow request id");
        let request_version_id = request["capabilityShadowTrialRequestVersionId"]
            .as_str()
            .expect("shadow request version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-shadow-request-exact"), request_id)
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityShadowTrialRequestResourceId": request_id,
                "expectedCapabilityShadowTrialRequestVersionId": request_version_id,
                "capabilityShadowTrialDecisionId": format!("{key}-shadow-decision"),
                "decision": decision,
                "reason": "Metadata-only shadow trial decision recorded.",
                "decisionEvidence": [{
                    "kind": "evidence",
                    "resourceId": "evidence:shadow-decision",
                    "role": "decision"
                }],
                "denialEvidence": [{
                    "kind": "evidence",
                    "resourceId": "evidence:shadow-denial",
                    "role": "denial"
                }]
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
        record_capability_shadow_trial_decision_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record shadow decision")
    }

    async fn shadow_run(&self, key: &str, decision: &Value, outcome: &str) -> Value {
        let decision_id = decision["capabilityShadowTrialDecisionResourceId"]
            .as_str()
            .expect("shadow decision id");
        let decision_version_id = decision["capabilityShadowTrialDecisionVersionId"]
            .as_str()
            .expect("shadow decision version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-shadow-decision-exact"), decision_id)
            .await;
        let mut payload = json!({
            "capabilityShadowTrialDecisionResourceId": decision_id,
            "expectedCapabilityShadowTrialDecisionVersionId": decision_version_id,
            "capabilityShadowTrialRunId": format!("{key}-shadow-run"),
            "capabilityShadowTrialEvidenceId": format!("{key}-shadow-evidence"),
            "trialRunOutcome": outcome,
            "auditRefs": [{
                "kind": "evidence",
                "resourceId": "evidence:shadow-run-audit",
                "role": "audit"
            }]
        });
        if outcome == "completed" {
            payload["builtInProjection"] = status_projection("clean");
            payload["candidateProjection"] = status_projection("clean");
        }
        let invocation = invocation(
            key,
            payload,
            grant_id,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        );
        record_capability_shadow_trial_run_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record shadow run")
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        let mut selectors = shadow_trial_kind_selectors();
        selectors.push(exact_selector);
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        let kinds = shadow_trial_kinds();
        derive_grant(
            &self.deps,
            suffix,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &kinds,
            &selector_refs,
            "none",
        )
        .await
    }

    async fn exact_write_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        let mut selectors = shadow_trial_kind_selectors();
        selectors.push(exact_selector);
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        let kinds = shadow_trial_kinds();
        derive_grant(
            &self.deps,
            suffix,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &kinds,
            &selector_refs,
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

struct RouteFixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl RouteFixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
        };
        let session_id = format!("{label}-session");
        let write_kinds = route_kinds();
        let write_selectors = route_kind_selectors();
        let write_selector_refs = write_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-route-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &write_kinds,
            &write_selector_refs,
            "none",
        )
        .await;
        let read_kinds = route_kinds();
        let read_selectors = route_kind_selectors();
        let read_selector_refs = read_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-route-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &read_kinds,
            &read_selector_refs,
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

    async fn candidate_invocation(&self, key: &str) -> Invocation {
        let shadow_evidence = self.shadow_evidence(&format!("{key}-shadow")).await;
        let shadow_evidence_id = shadow_evidence["capabilityShadowTrialEvidenceResourceId"]
            .as_str()
            .expect("shadow evidence id");
        let shadow_evidence_version_id = shadow_evidence["capabilityShadowTrialEvidenceVersionId"]
            .as_str()
            .expect("shadow evidence version id");
        let (module_lifecycle_ref, module_runtime_ref) =
            self.runtime_refs(&format!("{key}-runtime")).await;
        let lifecycle_id = module_lifecycle_ref["resourceId"]
            .as_str()
            .expect("lifecycle ref resource id");
        let runtime_id = module_runtime_ref["resourceId"]
            .as_str()
            .expect("runtime ref resource id");
        let grant_id = self
            .exact_write_grant(
                &format!("{key}-shadow-evidence-exact"),
                &[shadow_evidence_id, lifecycle_id, runtime_id],
            )
            .await;
        invocation(
            key,
            route_candidate_payload(
                key,
                shadow_evidence_id,
                shadow_evidence_version_id,
                &module_lifecycle_ref,
                &module_runtime_ref,
            ),
            grant_id,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        )
    }

    async fn runtime_refs(&self, key: &str) -> (Value, Value) {
        let scope = EngineResourceScope::Session(self.session_id.clone());
        let lifecycle_id = format!("module_lifecycle_state:{key}");
        let lifecycle = self
            .deps
            .engine_host
            .create_resource(CreateResource {
                resource_id: Some(lifecycle_id.clone()),
                kind: MODULE_LIFECYCLE_STATE_KIND.to_owned(),
                schema_id: Some(MODULE_LIFECYCLE_STATE_SCHEMA_ID.to_owned()),
                scope: scope.clone(),
                owner_worker_id: WorkerId::new("module_lifecycle").expect("worker id"),
                owner_actor_id: ActorId::new(format!("agent:{}", self.session_id))
                    .expect("actor id"),
                lifecycle: Some("enabled".to_owned()),
                policy: json!({"metadataOnly": true, "networkPolicy": "none"}),
                initial_payload: Some(route_lifecycle_payload(&scope, &lifecycle_id)),
                locations: vec![EngineResourceLocation {
                    kind: "module_lifecycle_state".to_owned(),
                    uri: format!("module-lifecycle-state:{key}"),
                    mime_type: Some("application/json".to_owned()),
                    size_bytes: None,
                }],
                trace_id: TraceId::new(format!("trace-route-lifecycle-{key}")).expect("trace id"),
                invocation_id: None,
            })
            .await
            .expect("create route lifecycle");
        let lifecycle_version_id = lifecycle
            .current_version_id
            .clone()
            .expect("lifecycle version");
        let runtime_id = format!("module_runtime_state:{key}");
        let runtime = self
            .deps
            .engine_host
            .create_resource(CreateResource {
                resource_id: Some(runtime_id.clone()),
                kind: MODULE_RUNTIME_STATE_KIND.to_owned(),
                schema_id: Some(MODULE_RUNTIME_STATE_SCHEMA_ID.to_owned()),
                scope: scope.clone(),
                owner_worker_id: WorkerId::new("module_runtime").expect("worker id"),
                owner_actor_id: ActorId::new(format!("agent:{}", self.session_id))
                    .expect("actor id"),
                lifecycle: Some("running".to_owned()),
                policy: json!({"metadataOnly": true, "networkPolicy": "none"}),
                initial_payload: Some(route_runtime_payload(
                    &scope,
                    &lifecycle_id,
                    &lifecycle_version_id,
                    key,
                )),
                locations: vec![EngineResourceLocation {
                    kind: "module_runtime_state".to_owned(),
                    uri: format!("module-runtime-state:{key}"),
                    mime_type: Some("application/json".to_owned()),
                    size_bytes: None,
                }],
                trace_id: TraceId::new(format!("trace-route-runtime-{key}")).expect("trace id"),
                invocation_id: None,
            })
            .await
            .expect("create route runtime");
        let runtime_version_id = runtime.current_version_id.clone().expect("runtime version");
        (
            json!({
                "kind": MODULE_LIFECYCLE_STATE_KIND,
                "resourceId": lifecycle_id,
                "versionId": lifecycle_version_id,
                "role": "lifecycle"
            }),
            json!({
                "kind": MODULE_RUNTIME_STATE_KIND,
                "resourceId": runtime_id,
                "versionId": runtime_version_id,
                "role": "runtime"
            }),
        )
    }

    async fn shadow_evidence(&self, key: &str) -> Value {
        let request = self.shadow_request(&format!("{key}-request")).await;
        let decision = self
            .shadow_decision(&format!("{key}-decision"), &request)
            .await;
        self.shadow_run(&format!("{key}-run"), &decision).await
    }

    async fn shadow_request(&self, key: &str) -> Value {
        let invocation = self.write_invocation(key, shadow_request_payload(key));
        record_capability_shadow_trial_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record route shadow request")
    }

    async fn shadow_decision(&self, key: &str, request: &Value) -> Value {
        let request_id = request["capabilityShadowTrialRequestResourceId"]
            .as_str()
            .expect("route shadow request id");
        let request_version_id = request["capabilityShadowTrialRequestVersionId"]
            .as_str()
            .expect("route shadow request version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-shadow-request-exact"), &[request_id])
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityShadowTrialRequestResourceId": request_id,
                "expectedCapabilityShadowTrialRequestVersionId": request_version_id,
                "capabilityShadowTrialDecisionId": format!("{key}-shadow-decision"),
                "decision": "approved",
                "reason": "Route candidate shadow evidence approved.",
                "decisionEvidence": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-shadow-decision",
                    "role": "decision"
                }]
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
        record_capability_shadow_trial_decision_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record route shadow decision")
    }

    async fn shadow_run(&self, key: &str, decision: &Value) -> Value {
        let decision_id = decision["capabilityShadowTrialDecisionResourceId"]
            .as_str()
            .expect("route shadow decision id");
        let decision_version_id = decision["capabilityShadowTrialDecisionVersionId"]
            .as_str()
            .expect("route shadow decision version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-shadow-decision-exact"), &[decision_id])
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityShadowTrialDecisionResourceId": decision_id,
                "expectedCapabilityShadowTrialDecisionVersionId": decision_version_id,
                "capabilityShadowTrialRunId": format!("{key}-shadow-run"),
                "capabilityShadowTrialEvidenceId": format!("{key}-shadow-evidence"),
                "trialRunOutcome": "completed",
                "builtInProjection": status_projection("clean"),
                "candidateProjection": status_projection("clean"),
                "auditRefs": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-shadow-run-audit",
                    "role": "audit"
                }]
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
        record_capability_shadow_trial_run_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record route shadow run")
    }

    async fn binding(&self, key: &str, candidate: &Value) -> Value {
        let candidate_id = candidate["capabilityReplacementCandidateResourceId"]
            .as_str()
            .expect("candidate id");
        let candidate_inspection = self
            .deps
            .engine_host
            .inspect_resource(candidate_id)
            .await
            .expect("inspect candidate resource internally")
            .expect("candidate resource exists");
        let (_, candidate_payload) =
            current_payload(&candidate_inspection, "candidate fixture payload")
                .expect("candidate current payload");
        let shadow_evidence_id = candidate_payload
            .pointer("/candidate/shadowEvidenceRef/resourceId")
            .and_then(Value::as_str)
            .expect("candidate shadow evidence id");
        let candidate_version_id = candidate["capabilityReplacementCandidateVersionId"]
            .as_str()
            .expect("candidate version id");
        let grant_id = self
            .exact_write_grant(
                &format!("{key}-candidate-exact"),
                &[candidate_id, shadow_evidence_id],
            )
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityReplacementCandidateResourceId": candidate_id,
                "expectedCapabilityReplacementCandidateVersionId": candidate_version_id,
                "capabilityRouteBindingId": format!("{key}-route-binding"),
                "routeVersion": "git-status-route-v1",
                "lifecycleState": "ready",
                "auditRefs": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-binding-audit",
                    "role": "audit"
                }]
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
        record_route_binding_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record route binding")
    }

    async fn activation(&self, key: &str, binding: &Value) -> Value {
        let binding_id = binding["capabilityRouteBindingResourceId"]
            .as_str()
            .expect("binding id");
        let binding_version_id = binding["capabilityRouteBindingVersionId"]
            .as_str()
            .expect("binding version id");
        let grant_id = self
            .exact_write_grant(&format!("{key}-binding-exact"), &[binding_id])
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityRouteBindingResourceId": binding_id,
                "expectedCapabilityRouteBindingVersionId": binding_version_id,
                "capabilityRouteActivationId": format!("{key}-route-activation"),
                "reason": "Activate scoped git_status route after approval.",
                "approvalRefs": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-approval",
                    "role": "approval"
                }],
                "auditRefs": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-activation-audit",
                    "role": "audit"
                }]
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
        activate_route_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("activate route")
    }

    async fn disable(&self, key: &str, binding: &Value, activation: &Value) -> Value {
        let binding_id = binding["capabilityRouteBindingResourceId"]
            .as_str()
            .expect("binding id");
        let binding_version_id = binding["capabilityRouteBindingVersionId"]
            .as_str()
            .expect("binding version id");
        let activation_id = activation["capabilityRouteActivationResourceId"]
            .as_str()
            .expect("activation id");
        let activation_version_id = activation["capabilityRouteActivationVersionId"]
            .as_str()
            .expect("activation version id");
        let grant_id = self
            .exact_write_grant(
                &format!("{key}-binding-activation-exact"),
                &[binding_id, activation_id],
            )
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityRouteBindingResourceId": binding_id,
                "expectedCapabilityRouteBindingVersionId": binding_version_id,
                "capabilityRouteActivationResourceId": activation_id,
                "expectedCapabilityRouteActivationVersionId": activation_version_id,
                "capabilityRouteActivationId": format!("{key}-disable-event"),
                "reason": "Disable scoped route and resume built-in projection.",
                "auditRefs": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-disable-audit",
                    "role": "audit"
                }]
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
        disable_route_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("disable route")
    }

    async fn rollback(&self, key: &str, binding: &Value, activation: &Value) -> Value {
        let binding_id = binding["capabilityRouteBindingResourceId"]
            .as_str()
            .expect("binding id");
        let binding_version_id = binding["capabilityRouteBindingVersionId"]
            .as_str()
            .expect("binding version id");
        let activation_id = activation["capabilityRouteActivationResourceId"]
            .as_str()
            .expect("activation id");
        let activation_version_id = activation["capabilityRouteActivationVersionId"]
            .as_str()
            .expect("activation version id");
        let grant_id = self
            .exact_write_grant(
                &format!("{key}-binding-activation-exact"),
                &[binding_id, activation_id],
            )
            .await;
        let invocation = invocation(
            key,
            json!({
                "capabilityRouteBindingResourceId": binding_id,
                "expectedCapabilityRouteBindingVersionId": binding_version_id,
                "capabilityRouteActivationResourceId": activation_id,
                "expectedCapabilityRouteActivationVersionId": activation_version_id,
                "capabilityRouteActivationId": format!("{key}-rollback-event"),
                "capabilityRouteRollbackId": format!("{key}-route-rollback"),
                "reason": "Roll back scoped route and restore built-in projection.",
                "auditRefs": [{
                    "kind": "evidence",
                    "resourceId": "evidence:route-rollback-audit",
                    "role": "audit"
                }]
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
        rollback_route_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("rollback route")
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        let mut selectors = route_kind_selectors();
        selectors.push(format!("resource:{resource_id}"));
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        let kinds = route_kinds();
        derive_grant(
            &self.deps,
            suffix,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &kinds,
            &selector_refs,
            "none",
        )
        .await
    }

    async fn exact_write_grant(&self, suffix: &str, resource_ids: &[&str]) -> AuthorityGrantId {
        let mut selectors = route_kind_selectors();
        selectors.extend(
            resource_ids
                .iter()
                .map(|resource_id| format!("resource:{resource_id}")),
        );
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        let kinds = route_kinds();
        derive_grant(
            &self.deps,
            suffix,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &kinds,
            &selector_refs,
            "none",
        )
        .await
    }

    async fn append_resource_version(&self, key: &str, resource_id: &str, expected_version: &str) {
        let inspection = self
            .deps
            .engine_host
            .inspect_resource(resource_id)
            .await
            .expect("inspect route resource")
            .expect("route resource exists");
        let current_version = inspection
            .versions
            .iter()
            .find(|version| version.version_id == expected_version)
            .expect("expected route resource version");
        let mut payload = current_version.payload.clone();
        payload["revision"] =
            json!(payload.get("revision").and_then(Value::as_u64).unwrap_or(1) + 1);
        payload["updatedAt"] = json!("2026-06-27T12:01:00Z");
        let update_invocation = self.write_invocation(key, json!({}));
        self.deps
            .engine_host
            .update_resource(UpdateResource {
                resource_id: resource_id.to_owned(),
                expected_current_version_id: Some(expected_version.to_owned()),
                lifecycle: Some(inspection.resource.lifecycle),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: update_invocation.causal_context.trace_id,
                invocation_id: Some(update_invocation.id),
            })
            .await
            .expect("append route resource version");
    }

    async fn set_resource_lifecycle(&self, key: &str, resource_id: &str, lifecycle: &str) {
        let inspection = self
            .deps
            .engine_host
            .inspect_resource(resource_id)
            .await
            .expect("inspect route resource")
            .expect("route resource exists");
        let (current_version, current_payload) =
            current_payload(&inspection, "route fixture lifecycle update")
                .expect("current payload");
        let mut payload = current_payload.clone();
        payload["state"] = json!(lifecycle);
        payload["revision"] =
            json!(payload.get("revision").and_then(Value::as_u64).unwrap_or(1) + 1);
        payload["updatedAt"] = json!("2026-06-27T12:01:00Z");
        let update_invocation = self.write_invocation(key, json!({}));
        self.deps
            .engine_host
            .update_resource(UpdateResource {
                resource_id: resource_id.to_owned(),
                expected_current_version_id: Some(current_version.version_id.clone()),
                lifecycle: Some(lifecycle.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: update_invocation.causal_context.trace_id,
                invocation_id: Some(update_invocation.id),
            })
            .await
            .expect("set route fixture resource lifecycle");
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

#[test]
fn capability_shadow_trial_resource_types_are_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    for (kind, schema_id) in [
        (
            CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
            CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_ID,
        ),
        (
            CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
            CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_ID,
        ),
        (
            CAPABILITY_SHADOW_TRIAL_RUN_KIND,
            CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_ID,
        ),
        (
            CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
            CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_ID,
        ),
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.kind == kind)
            .expect("capability shadow trial definition");
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
        assert!(
            definition.redaction_rules["neverReturn"]
                .as_array()
                .expect("redaction list")
                .contains(&json!("rawCommand"))
        );
    }
}

#[test]
fn capability_route_resource_types_are_registered_with_governed_runtime_bounds() {
    let definitions = builtin_resource_type_definitions();
    for (kind, schema_id) in [
        (
            CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
            CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_ID,
        ),
        (
            CAPABILITY_ROUTE_BINDING_KIND,
            CAPABILITY_ROUTE_BINDING_SCHEMA_ID,
        ),
        (
            CAPABILITY_ROUTE_ACTIVATION_KIND,
            CAPABILITY_ROUTE_ACTIVATION_SCHEMA_ID,
        ),
        (
            CAPABILITY_ROUTE_EVENT_KIND,
            CAPABILITY_ROUTE_EVENT_SCHEMA_ID,
        ),
        (
            CAPABILITY_ROUTE_ROLLBACK_KIND,
            CAPABILITY_ROUTE_ROLLBACK_SCHEMA_ID,
        ),
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.kind == kind)
            .expect("capability route definition");
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
            definition.materialization_rules["runtimeRouting"],
            json!("governed_explicit_scoped_reversible")
        );
        assert_eq!(
            definition.materialization_rules["networkPolicy"],
            json!("none")
        );
        assert_eq!(
            definition.materialization_rules["dispatchMutation"],
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
async fn route_records_candidate_binding_activation_disable_and_rollback_for_git_status() {
    let fixture = RouteFixture::new("capability-route-flow").await;

    let candidate_invocation = fixture.candidate_invocation("candidate").await;
    let candidate = record_replacement_candidate_value_at(
        &fixture.deps,
        &candidate_invocation,
        &candidate_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record candidate");
    assert_eq!(candidate["status"], json!("validated"));
    assert_eq!(
        candidate["replacementCandidate"]["operation"]["name"],
        json!("git_status")
    );
    assert_eq!(
        candidate["replacementCandidate"]["candidate"]["moduleAdapterInvokedByDispatcher"],
        json!(true)
    );
    let replay = record_replacement_candidate_value_at(
        &fixture.deps,
        &candidate_invocation,
        &candidate_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("replay candidate");
    assert_eq!(replay["idempotentReplay"], json!(true));

    let candidate_id = candidate["capabilityReplacementCandidateResourceId"]
        .as_str()
        .expect("candidate id");
    let candidate_read_grant = fixture
        .exact_read_grant("candidate-read-exact", candidate_id)
        .await;
    let inspected_candidate = inspect_replacement_candidate_value(
        &fixture.deps,
        &invocation(
            "candidate-inspect",
            json!({"capabilityReplacementCandidateResourceId": candidate_id}),
            candidate_read_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"capabilityReplacementCandidateResourceId": candidate_id}),
    )
    .await
    .expect("inspect candidate");
    assert_eq!(
        inspected_candidate["replacementCandidate"]["projection"]["rawCommandsReturned"],
        json!(false)
    );
    assert_eq!(
        inspected_candidate["replacementCandidate"]["sideEffectProof"]["runtimeRoutingChanged"],
        json!(false)
    );

    let binding = fixture.binding("binding", &candidate).await;
    assert_eq!(binding["status"], json!("ready"));
    assert_eq!(
        binding["routeBinding"]["binding"]["routeCanActivate"],
        json!(true)
    );
    assert_eq!(
        binding["routeBinding"]["binding"]["shadowEvidence"]["kind"],
        json!(CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND)
    );

    let binding_id = binding["capabilityRouteBindingResourceId"]
        .as_str()
        .expect("binding id");
    let binding_read_grant = fixture
        .exact_read_grant("binding-read-exact", binding_id)
        .await;
    let inspected_binding = inspect_route_binding_value(
        &fixture.deps,
        &invocation(
            "binding-inspect",
            json!({"capabilityRouteBindingResourceId": binding_id}),
            binding_read_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"capabilityRouteBindingResourceId": binding_id}),
    )
    .await
    .expect("inspect binding");
    assert_eq!(
        inspected_binding["routeBinding"]["projection"]["providerSafe"],
        json!(true)
    );

    assert!(
        active_route_for_git_status(
            &fixture.deps,
            &fixture.read_invocation("route-before-activation", json!({}))
        )
        .await
        .expect("route lookup before activation")
        .is_none()
    );

    let activation = fixture.activation("activation", &binding).await;
    assert_eq!(activation["status"], json!("active"));
    assert_eq!(
        activation["routeActivation"]["activation"]["runtimeRoutingEnabled"],
        json!(true)
    );

    let active = active_route_for_git_status(
        &fixture.deps,
        &fixture.read_invocation("route-after-activation", json!({})),
    )
    .await
    .expect("route lookup after activation")
    .expect("active route");
    assert_eq!(active.route_version, "git-status-route-v1");
    assert_eq!(active.candidate_owner, "module:git-status-shadow");
    let routed = execute_routed_git_status(
        &fixture.deps,
        &fixture.read_invocation("route-execute", json!({})),
        &active,
    )
    .await
    .expect("execute routed git_status");
    assert_eq!(routed.is_error, Some(false));
    let routed_details = routed.details.expect("routed details");
    assert_eq!(
        routed_details["dynamicReplacement"]["moduleAdapterInvoked"],
        json!(true)
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["builtInProjectionUsed"],
        json!(false)
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["routeState"],
        json!("active_route_module_adapter_projection")
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["adapterRuntime"]["moduleLifecycle"]["runtimeAuthorizationChecked"],
        json!(true)
    );
    assert!(
        !contains_json_key(&routed_details, "moduleRuntimeResourceId"),
        "routed provider details must not expose raw runtime resource IDs"
    );
    assert!(
        !contains_json_key(&routed_details, "resourceId"),
        "routed provider details must not expose raw resource IDs"
    );
    assert!(
        !contains_json_key(&routed_details, "versionId"),
        "routed provider details must not expose raw version IDs"
    );
    assert!(
        !contains_json_key(&routed_details, "idempotencyFingerprint"),
        "routed provider details must not expose idempotency fingerprints"
    );
    assert!(
        routed_details["git"].get("evidenceRef").is_none(),
        "routed git projection must summarize evidence instead of exposing raw refs"
    );
    assert_eq!(
        routed_details["git"]["evidence"]["resourceIdRedacted"],
        json!(true)
    );

    let events = list_route_event_value(
        &fixture.deps,
        &fixture.read_invocation("route-events", json!({"includeArchived": true})),
        &json!({"includeArchived": true}),
    )
    .await
    .expect("list route events");
    assert_eq!(events["sideEffects"]["dispatchTableMutated"], json!(false));
    assert!(
        events["routeEvents"]
            .as_array()
            .expect("route events")
            .iter()
            .any(|event| event["event"]["kind"] == json!("activated"))
    );
    for event in events["routeEvents"].as_array().expect("route events") {
        assert!(
            !contains_json_key(event, "resourceId"),
            "route event list must not expose raw resource IDs at any depth"
        );
        assert!(
            !contains_json_key(event, "versionId"),
            "route event list must not expose raw version IDs at any depth"
        );
        assert!(
            !contains_json_key(event, "currentVersionId"),
            "route event list must not expose raw current version IDs at any depth"
        );
        assert!(
            !contains_json_key(event, "activationResourceId"),
            "route event list must not expose raw activation resource IDs at any depth"
        );
        assert!(
            !contains_json_key(event, "activationVersionId"),
            "route event list must not expose raw activation version IDs at any depth"
        );
        assert_eq!(event["resourceRefs"][0]["resourceIdRedacted"], json!(true));
        assert_eq!(event["resourceRefs"][0]["versionIdRedacted"], json!(true));
        assert!(contains_json_key(event, "resourceIdRedacted"));
        assert!(contains_json_key(event, "versionIdRedacted"));
    }
    let route_event_id = fixture
        .deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(CAPABILITY_ROUTE_EVENT_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(fixture.session_id.clone())),
            lifecycle: None,
            limit: 1,
        })
        .await
        .expect("list route event resources internally")[0]
        .resource_id
        .clone();
    let event_read_grant = fixture
        .exact_read_grant("event-read-exact", &route_event_id)
        .await;
    let inspected_event = inspect_route_event_value(
        &fixture.deps,
        &invocation(
            "route-event-inspect",
            json!({"capabilityRouteEventResourceId": route_event_id}),
            event_read_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"capabilityRouteEventResourceId": route_event_id}),
    )
    .await
    .expect("inspect route event");
    assert_eq!(
        inspected_event["routeEvent"]["projection"]["rawAuthorityIdsReturned"],
        json!(false)
    );

    let disabled = fixture.disable("disable", &binding, &activation).await;
    assert_eq!(disabled["status"], json!("disabled"));
    assert_eq!(disabled["routeEvent"]["event"]["kind"], json!("disabled"));
    assert!(
        active_route_for_git_status(
            &fixture.deps,
            &fixture.read_invocation("route-after-disable", json!({}))
        )
        .await
        .expect("route lookup after disable")
        .is_none()
    );

    let rollback = fixture.rollback("rollback", &binding, &activation).await;
    assert_eq!(rollback["status"], json!("rolled_back"));
    assert_eq!(
        rollback["routeRollback"]["rollback"]["builtInRestored"],
        json!(true)
    );
    assert!(
        active_route_for_git_status(
            &fixture.deps,
            &fixture.read_invocation("route-after-rollback", json!({}))
        )
        .await
        .expect("route lookup after rollback")
        .is_none()
    );
}

#[tokio::test]
async fn active_route_rejects_unsafe_adapter_projection_without_builtin_fallback() {
    let fixture = RouteFixture::new("capability-route-fail-closed").await;

    let candidate_invocation = fixture.candidate_invocation("candidate").await;
    let candidate = record_replacement_candidate_value_at(
        &fixture.deps,
        &candidate_invocation,
        &candidate_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record candidate");
    let binding = fixture.binding("binding", &candidate).await;
    fixture.activation("activation", &binding).await;

    let mut active = active_route_for_git_status(
        &fixture.deps,
        &fixture.read_invocation("route-after-activation", json!({})),
    )
    .await
    .expect("route lookup after activation")
    .expect("active route");
    active.candidate_projection = json!({
        "operation": "git_status",
        "status": "clean",
        "headState": "clean"
    });

    assert_route_execution_failed_closed(&fixture, &active, "route-execute-rejected").await;
}

#[tokio::test]
async fn active_route_rejects_stale_runtime_ref_without_builtin_fallback() {
    let (fixture, active) = activated_route_fixture("capability-route-stale-runtime").await;
    let runtime_id = active.module_runtime_ref["resourceId"]
        .as_str()
        .expect("runtime resource id");
    let runtime_version_id = active.module_runtime_ref["versionId"]
        .as_str()
        .expect("runtime version id");

    fixture
        .append_resource_version("runtime-stale-update", runtime_id, runtime_version_id)
        .await;

    assert_route_execution_failed_closed(&fixture, &active, "runtime-stale-execute").await;
}

#[tokio::test]
async fn active_route_rejects_stale_lifecycle_ref_without_builtin_fallback() {
    let (fixture, active) = activated_route_fixture("capability-route-stale-lifecycle").await;
    let lifecycle_id = active.module_lifecycle_ref["resourceId"]
        .as_str()
        .expect("lifecycle resource id");
    let lifecycle_version_id = active.module_lifecycle_ref["versionId"]
        .as_str()
        .expect("lifecycle version id");

    fixture
        .append_resource_version("lifecycle-stale-update", lifecycle_id, lifecycle_version_id)
        .await;

    assert_route_execution_failed_closed(&fixture, &active, "lifecycle-stale-execute").await;
}

#[tokio::test]
async fn active_route_rejects_disabled_lifecycle_without_builtin_fallback() {
    let (fixture, active) = activated_route_fixture("capability-route-disabled-lifecycle").await;
    let lifecycle_id = active.module_lifecycle_ref["resourceId"]
        .as_str()
        .expect("lifecycle resource id");

    fixture
        .set_resource_lifecycle("lifecycle-disable", lifecycle_id, "disabled")
        .await;

    assert_route_execution_failed_closed(&fixture, &active, "lifecycle-disabled-execute").await;
}

#[tokio::test]
async fn active_route_rejects_cancelled_runtime_without_builtin_fallback() {
    let (fixture, active) = activated_route_fixture("capability-route-cancelled-runtime").await;
    let runtime_id = active.module_runtime_ref["resourceId"]
        .as_str()
        .expect("runtime resource id");

    fixture
        .set_resource_lifecycle("runtime-cancel", runtime_id, "cancelled")
        .await;

    assert_route_execution_failed_closed(&fixture, &active, "runtime-cancelled-execute").await;
}

fn contains_json_key(value: &Value, target: &str) -> bool {
    match value {
        Value::Object(object) => object
            .iter()
            .any(|(key, value)| key == target || contains_json_key(value, target)),
        Value::Array(items) => items.iter().any(|value| contains_json_key(value, target)),
        _ => false,
    }
}

async fn assert_failed_closed_lookup_event(
    fixture: &RouteFixture,
    key: &str,
    expected_result: &str,
) {
    let events = list_route_event_value(
        &fixture.deps,
        &fixture.read_invocation(key, json!({"includeArchived": true})),
        &json!({"includeArchived": true}),
    )
    .await
    .expect("list route events");
    let failed = events["routeEvents"]
        .as_array()
        .expect("route events")
        .iter()
        .find(|event| {
            event["state"] == json!("failed_closed")
                && event["event"]["kind"] == json!("route_lookup_failed")
                && event["event"]["result"] == json!(expected_result)
        })
        .expect("failed-closed lookup event");
    assert!(
        !contains_json_key(failed, "resourceId"),
        "failed lookup event list must not expose raw resource IDs"
    );
    assert!(
        !contains_json_key(failed, "versionId"),
        "failed lookup event list must not expose raw version IDs"
    );
    assert_eq!(failed["resourceRefs"][0]["resourceIdRedacted"], json!(true));
    assert_eq!(failed["resourceRefs"][0]["versionIdRedacted"], json!(true));
}

async fn activated_route_fixture(label: &str) -> (RouteFixture, ActiveRoute) {
    let fixture = RouteFixture::new(label).await;
    let candidate_invocation = fixture.candidate_invocation("candidate").await;
    let candidate = record_replacement_candidate_value_at(
        &fixture.deps,
        &candidate_invocation,
        &candidate_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record candidate");
    let binding = fixture.binding("binding", &candidate).await;
    fixture.activation("activation", &binding).await;
    let active = active_route_for_git_status(
        &fixture.deps,
        &fixture.read_invocation("route-after-activation", json!({})),
    )
    .await
    .expect("route lookup after activation")
    .expect("active route");
    (fixture, active)
}

async fn assert_route_execution_failed_closed(
    fixture: &RouteFixture,
    active: &ActiveRoute,
    key: &str,
) -> Value {
    let routed = execute_routed_git_status(
        &fixture.deps,
        &fixture.read_invocation(key, json!({})),
        active,
    )
    .await
    .expect("execute rejected routed git_status");
    assert_eq!(routed.is_error, Some(true));
    let routed_details = routed.details.expect("routed details");
    assert_eq!(routed_details["status"], json!("failed_closed"));
    assert_eq!(
        routed_details["dynamicReplacement"]["routeState"],
        json!("active_route_failed_closed")
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["moduleAdapterInvoked"],
        json!(true)
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["builtInProjectionUsed"],
        json!(false)
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["failureKind"],
        json!("adapter_projection_rejected")
    );
    assert!(
        routed_details["dynamicReplacement"]
            .as_object()
            .expect("dynamic replacement object")
            .get("failure")
            .is_none(),
        "provider-visible route failure must not expose raw internal error text"
    );
    assert!(
        routed_details.get("git").is_none(),
        "failed active routes must not return a built-in git success projection"
    );
    assert!(
        !contains_json_key(&routed_details, "moduleRuntimeResourceId"),
        "failed route details must not expose raw runtime resource IDs"
    );
    assert!(
        !contains_json_key(&routed_details, "resourceId"),
        "failed route details must not expose raw resource IDs"
    );
    assert!(
        !contains_json_key(&routed_details, "versionId"),
        "failed route details must not expose raw version IDs"
    );
    assert!(
        !contains_json_key(&routed_details, "idempotencyFingerprint"),
        "failed route details must not expose idempotency fingerprints"
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["routeEvent"]["state"],
        json!("failed_closed")
    );
    assert_eq!(
        routed_details["dynamicReplacement"]["routeEvent"]["event"]["result"],
        json!("adapter_projection_failed")
    );
    routed_details
}

#[tokio::test]
async fn route_lookup_rejects_stale_binding_or_candidate_current_versions() {
    let binding_fixture = RouteFixture::new("capability-route-stale-binding").await;
    let candidate_invocation = binding_fixture
        .candidate_invocation("binding-stale-candidate")
        .await;
    let candidate = record_replacement_candidate_value_at(
        &binding_fixture.deps,
        &candidate_invocation,
        &candidate_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record candidate");
    let binding = binding_fixture.binding("binding-stale", &candidate).await;
    let binding_id = binding["capabilityRouteBindingResourceId"]
        .as_str()
        .expect("binding id");
    let binding_version_id = binding["capabilityRouteBindingVersionId"]
        .as_str()
        .expect("binding version id");
    let _activation = binding_fixture
        .activation("binding-stale-activation", &binding)
        .await;
    binding_fixture
        .append_resource_version("binding-stale-update", binding_id, binding_version_id)
        .await;
    let error = active_route_for_git_status(
        &binding_fixture.deps,
        &binding_fixture.read_invocation("binding-stale-lookup", json!({})),
    )
    .await
    .expect_err("stale binding version rejects active route lookup")
    .to_string();
    assert!(
        error.contains("stale capability route binding version"),
        "{error}"
    );
    assert_failed_closed_lookup_event(
        &binding_fixture,
        "binding-stale-events",
        "referenced_route_record_rejected",
    )
    .await;

    let candidate_fixture = RouteFixture::new("capability-route-stale-candidate").await;
    let candidate_invocation = candidate_fixture
        .candidate_invocation("candidate-stale-candidate")
        .await;
    let candidate = record_replacement_candidate_value_at(
        &candidate_fixture.deps,
        &candidate_invocation,
        &candidate_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record candidate");
    let candidate_id = candidate["capabilityReplacementCandidateResourceId"]
        .as_str()
        .expect("candidate id");
    let candidate_version_id = candidate["capabilityReplacementCandidateVersionId"]
        .as_str()
        .expect("candidate version id");
    let binding = candidate_fixture
        .binding("candidate-stale-binding", &candidate)
        .await;
    let _activation = candidate_fixture
        .activation("candidate-stale-activation", &binding)
        .await;
    candidate_fixture
        .append_resource_version("candidate-stale-update", candidate_id, candidate_version_id)
        .await;
    let error = active_route_for_git_status(
        &candidate_fixture.deps,
        &candidate_fixture.read_invocation("candidate-stale-lookup", json!({})),
    )
    .await
    .expect_err("stale candidate version rejects active route lookup")
    .to_string();
    assert!(
        error.contains("stale capability replacement candidate version"),
        "{error}"
    );
    assert_failed_closed_lookup_event(
        &candidate_fixture,
        "candidate-stale-events",
        "referenced_route_record_rejected",
    )
    .await;
}

#[tokio::test]
async fn route_candidate_rejects_fabricated_or_stale_shadow_evidence() {
    let fixture = RouteFixture::new("capability-route-evidence-guards").await;
    let fake_evidence_id = "capability_shadow_trial_evidence:missing-route-proof";
    let grant_id = fixture
        .exact_write_grant("fake-evidence-exact", &[fake_evidence_id])
        .await;
    let fake_invocation = invocation(
        "fake-evidence-candidate",
        route_candidate_payload(
            "fake-evidence",
            fake_evidence_id,
            "missing-version",
            &synthetic_lifecycle_ref("fake-evidence"),
            &synthetic_runtime_ref("fake-evidence"),
        ),
        grant_id,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &fake_invocation,
        &fake_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("fake shadow evidence must be rejected")
    .to_string();
    assert!(
        error.contains("missing capability shadow trial evidence"),
        "{error}"
    );

    let shadow_evidence = fixture.shadow_evidence("stale-shadow").await;
    let evidence_id = shadow_evidence["capabilityShadowTrialEvidenceResourceId"]
        .as_str()
        .expect("shadow evidence id");
    let grant_id = fixture
        .exact_write_grant("stale-evidence-exact", &[evidence_id])
        .await;
    let stale_invocation = invocation(
        "stale-evidence-candidate",
        route_candidate_payload(
            "stale-evidence",
            evidence_id,
            "stale-version",
            &synthetic_lifecycle_ref("stale-evidence"),
            &synthetic_runtime_ref("stale-evidence"),
        ),
        grant_id,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &stale_invocation,
        &stale_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("stale shadow evidence must be rejected")
    .to_string();
    assert!(
        error.contains("stale capability shadow trial evidence"),
        "{error}"
    );
}

#[tokio::test]
async fn route_candidate_rejects_target_and_authority_spoofing() {
    let fixture = RouteFixture::new("capability-route-authority-guards").await;

    let mut target_mismatch = fixture.candidate_invocation("target-mismatch").await;
    target_mismatch.payload["replacementTarget"] = json!("different_future_adapter");
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &target_mismatch,
        &target_mismatch.payload,
        default_operation_at(),
    )
    .await
    .expect_err("route candidate replacement target mismatch rejected")
    .to_string();
    assert!(
        error.contains("replacementTarget mismatch for git_status"),
        "{error}"
    );

    let mut wildcard_selector = fixture.candidate_invocation("wildcard-selector").await;
    wildcard_selector.payload["authorityConstraints"]["resourceSelectors"] = json!(["resource:*"]);
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &wildcard_selector,
        &wildcard_selector.payload,
        default_operation_at(),
    )
    .await
    .expect_err("route candidate wildcard selector rejected")
    .to_string();
    assert!(error.contains("wildcard resource selectors"), "{error}");

    let mut broad_selector = fixture.candidate_invocation("broad-selector").await;
    broad_selector.payload["authorityConstraints"]["resourceSelectors"] =
        json!(["kind:git_status_shadow_projection"]);
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &broad_selector,
        &broad_selector.payload,
        default_operation_at(),
    )
    .await
    .expect_err("route candidate non-resource selector rejected")
    .to_string();
    assert!(error.contains("resource-scoped exact selectors"), "{error}");

    let mut agent_state_kind = fixture.candidate_invocation("agent-state-kind").await;
    agent_state_kind.payload["authorityConstraints"]["resourceKinds"] = json!(["agent_state"]);
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &agent_state_kind,
        &agent_state_kind.payload,
        default_operation_at(),
    )
    .await
    .expect_err("route candidate agent_state resource kind rejected")
    .to_string();
    assert!(
        error.contains("rejects agent_state resourceKinds"),
        "{error}"
    );

    let mut agent_state_inherited = fixture.candidate_invocation("agent-state-inherited").await;
    agent_state_inherited.payload["authorityConstraints"]["agentStateInherited"] = json!(true);
    let error = record_replacement_candidate_value_at(
        &fixture.deps,
        &agent_state_inherited,
        &agent_state_inherited.payload,
        default_operation_at(),
    )
    .await
    .expect_err("route candidate agent_state inheritance rejected")
    .to_string();
    assert!(error.contains("rejects agent_state inheritance"), "{error}");
}

#[tokio::test]
async fn shadow_trial_records_git_status_request_decision_run_and_evidence_without_dispatch_change()
{
    let fixture = ShadowFixture::new("capability-shadow-flow").await;
    let before = crate::domains::capability::operation_binding_metadata("git_status")
        .expect("git status metadata");
    let request = fixture.shadow_request("shadow-request").await;
    assert_eq!(request["status"], json!("pending_review"));
    assert_eq!(request["idempotentReplay"], json!(false));
    assert_eq!(
        request["shadowTrialRequest"]["operation"]["name"],
        json!("git_status")
    );
    assert_eq!(
        request["shadowTrialRequest"]["operation"]["dispatchChanged"],
        json!(false)
    );
    assert_eq!(
        request["shadowTrialRequest"]["candidate"]["executionMode"],
        json!("metadata_only")
    );
    assert_eq!(
        request["shadowTrialRequest"]["requirements"]["authority"]["networkPolicy"],
        json!("none")
    );
    assert_eq!(
        request["shadowTrialRequest"]["requirements"]["authority"]["exactSelectorsRequired"],
        json!(true)
    );
    let replay = fixture.shadow_request("shadow-request").await;
    assert_eq!(replay["idempotentReplay"], json!(true));

    let decision = fixture
        .shadow_decision("shadow-decision", &request, "approved")
        .await;
    assert_eq!(decision["status"], json!("approved_trial"));
    assert_eq!(
        decision["shadowTrialDecision"]["runGate"]["runAllowed"],
        json!(true)
    );
    assert_eq!(
        decision["shadowTrialDecision"]["sideEffectProof"]["dispatchTableMutated"],
        json!(false)
    );

    let run = fixture
        .shadow_run("shadow-run", &decision, "completed")
        .await;
    assert_eq!(run["status"], json!("passed"));
    assert_eq!(
        run["shadowTrialRun"]["run"]["candidateExecuted"],
        json!(false)
    );
    assert_eq!(
        run["shadowTrialRun"]["resultControls"]["rollbackAvailable"],
        json!(true)
    );
    assert_eq!(
        run["shadowTrialEvidence"]["comparison"]["result"],
        json!("equivalent")
    );
    assert_eq!(
        run["shadowTrialEvidence"]["sideEffectProof"]["runtimeRoutingChanged"],
        json!(false)
    );

    let evidence_id = run["capabilityShadowTrialEvidenceResourceId"]
        .as_str()
        .expect("evidence id");
    let evidence_version_id = run["capabilityShadowTrialEvidenceVersionId"]
        .as_str()
        .expect("evidence version id");
    let evidence_grant = fixture
        .exact_read_grant("shadow-evidence-exact", evidence_id)
        .await;
    let inspected = inspect_capability_shadow_trial_evidence_value(
        &fixture.deps,
        &invocation(
            "shadow-evidence-inspect",
            json!({
                "capabilityShadowTrialEvidenceResourceId": evidence_id,
                "expectedCapabilityShadowTrialEvidenceVersionId": evidence_version_id
            }),
            evidence_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({
            "capabilityShadowTrialEvidenceResourceId": evidence_id,
            "expectedCapabilityShadowTrialEvidenceVersionId": evidence_version_id
        }),
    )
    .await
    .expect("inspect shadow evidence");
    assert_eq!(
        inspected["shadowTrialEvidence"]["projection"]["providerSafe"],
        json!(true)
    );
    assert_eq!(
        inspected["shadowTrialEvidence"]["shadowTrialEvidence"]["candidateProjection"]["rawPathsStored"],
        json!(false)
    );
    assert_eq!(
        inspected["shadowTrialEvidence"]["shadowTrialEvidence"]["authority"]["agentStateInherited"],
        json!(false)
    );

    let after = crate::domains::capability::operation_binding_metadata("git_status")
        .expect("git status metadata after");
    assert_eq!(before, after);
    assert!(crate::domains::capability::supported_operation_names().contains(&"git_status"));
    assert!(
        crate::domains::capability::supported_operation_names()
            .contains(&"capability_shadow_trial_run_record")
    );
}

#[tokio::test]
async fn shadow_trial_rejects_non_git_status_wildcards_stale_evidence_and_missing_exact_selectors()
{
    let fixture = ShadowFixture::new("capability-shadow-guards").await;

    let mut wrong_target = shadow_request_payload("wrong-target");
    wrong_target["targetOperation"] = json!("git_diff");
    let wrong_invocation = fixture.write_invocation("wrong-target", wrong_target);
    let error = record_capability_shadow_trial_request_value_at(
        &fixture.deps,
        &wrong_invocation,
        &wrong_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wrong target rejected")
    .to_string();
    assert!(
        error.contains("target must be exactly git_status"),
        "{error}"
    );

    let mut wildcard_payload = shadow_request_payload("wildcard-selector");
    wildcard_payload["authorityConstraints"]["resourceSelectors"] = json!(["resource:*"]);
    let wildcard_payload_invocation =
        fixture.write_invocation("wildcard-selector", wildcard_payload);
    let error = record_capability_shadow_trial_request_value_at(
        &fixture.deps,
        &wildcard_payload_invocation,
        &wildcard_payload_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wildcard selector rejected")
    .to_string();
    assert!(error.contains("non-wildcard token"), "{error}");

    let wildcard_grant_id = derive_grant(
        &fixture.deps,
        "shadow-wildcard-wide",
        &["*"],
        &["*"],
        &["*"],
        "none",
    )
    .await;
    let wildcard_invocation = invocation(
        "shadow-wildcard-wide",
        shadow_request_payload("shadow-wildcard-wide"),
        wildcard_grant_id,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_capability_shadow_trial_request_value_at(
        &fixture.deps,
        &wildcard_invocation,
        &wildcard_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("wildcard grant rejected")
    .to_string();
    assert!(error.contains("wildcard grants"), "{error}");

    let request = fixture.shadow_request("selector-source").await;
    let decision = fixture
        .shadow_decision("selector-decision", &request, "approved")
        .await;
    let run = fixture
        .shadow_run("selector-run", &decision, "completed")
        .await;
    let evidence_id = run["capabilityShadowTrialEvidenceResourceId"]
        .as_str()
        .expect("evidence id");
    let selector_denied = inspect_capability_shadow_trial_evidence_value(
        &fixture.deps,
        &fixture.read_invocation(
            "shadow-selector-denied",
            json!({"capabilityShadowTrialEvidenceResourceId": evidence_id}),
        ),
        &json!({"capabilityShadowTrialEvidenceResourceId": evidence_id}),
    )
    .await
    .expect_err("exact evidence selector required")
    .to_string();
    assert!(
        selector_denied.contains("exact resource:"),
        "{selector_denied}"
    );

    let evidence_grant = fixture
        .exact_read_grant("shadow-stale-evidence-exact", evidence_id)
        .await;
    let stale = inspect_capability_shadow_trial_evidence_value(
        &fixture.deps,
        &invocation(
            "shadow-stale-evidence",
            json!({
                "capabilityShadowTrialEvidenceResourceId": evidence_id,
                "expectedCapabilityShadowTrialEvidenceVersionId": "old-version"
            }),
            evidence_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({
            "capabilityShadowTrialEvidenceResourceId": evidence_id,
            "expectedCapabilityShadowTrialEvidenceVersionId": "old-version"
        }),
    )
    .await
    .expect_err("stale evidence rejected")
    .to_string();
    assert!(
        stale.contains("stale capability shadow trial evidence"),
        "{stale}"
    );
}

#[tokio::test]
async fn shadow_trial_records_abort_and_disable_semantics_without_live_replacement() {
    let fixture = ShadowFixture::new("capability-shadow-controls").await;
    let request = fixture.shadow_request("control-request").await;
    let decision = fixture
        .shadow_decision("control-decision", &request, "approved")
        .await;

    let aborted = fixture
        .shadow_run("control-aborted", &decision, "aborted")
        .await;
    assert_eq!(aborted["status"], json!("aborted"));
    assert_eq!(
        aborted["shadowTrialRun"]["resultControls"]["abortAvailable"],
        json!(true)
    );
    assert_eq!(
        aborted["shadowTrialRun"]["sideEffectProof"]["hotSwapPerformed"],
        json!(false)
    );
    assert_eq!(
        aborted["shadowTrialEvidence"]["comparison"]["candidateExecuted"],
        json!(false)
    );

    let disabled = fixture
        .shadow_run("control-disabled", &decision, "disabled")
        .await;
    assert_eq!(disabled["status"], json!("disabled"));
    assert_eq!(
        disabled["shadowTrialRun"]["resultControls"]["disableAvailable"],
        json!(true)
    );
    assert_eq!(
        disabled["shadowTrialRun"]["resultControls"]["liveReplacementPerformed"],
        json!(false)
    );
    assert_eq!(
        disabled["shadowTrialRun"]["sideEffectProof"]["dispatchTableMutated"],
        json!(false)
    );
}

#[tokio::test]
async fn cockpit_overview_projects_operation_ownership_binding_shadow_and_rollback_without_raw_leakage()
 {
    let fixture = Fixture::new("capability-cockpit").await;
    let binding_request = fixture.binding_request("cockpit-binding").await;
    let rejected = fixture
        .binding_decision("cockpit-binding-rejected", &binding_request, "rejected")
        .await;
    assert_eq!(rejected["status"], json!("rejected"));

    let shadow_kinds = shadow_trial_kinds();
    let shadow_selectors = shadow_trial_kind_selectors();
    let shadow_selector_refs = shadow_selectors
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    let shadow_fixture = ShadowFixture {
        deps: fixture.deps.clone(),
        session_id: fixture.session_id.clone(),
        write_grant_id: derive_grant(
            &fixture.deps,
            "capability-cockpit-shadow-write",
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &shadow_kinds,
            &shadow_selector_refs,
            "none",
        )
        .await,
        read_grant_id: derive_grant(
            &fixture.deps,
            "capability-cockpit-shadow-read",
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &shadow_kinds,
            &shadow_selector_refs,
            "none",
        )
        .await,
    };
    let shadow_request = shadow_fixture.shadow_request("cockpit-shadow").await;
    let shadow_decision = shadow_fixture
        .shadow_decision("cockpit-shadow-decision", &shadow_request, "approved")
        .await;
    let shadow_run = shadow_fixture
        .shadow_run("cockpit-shadow-run", &shadow_decision, "completed")
        .await;
    assert_eq!(shadow_run["status"], json!("passed"));

    let overview = cockpit_overview_value(
        &fixture.deps,
        &fixture.read_invocation("cockpit-overview", json!({"limit": 200})),
    )
    .await
    .expect("cockpit overview");

    assert_eq!(
        overview["schemaVersion"],
        json!(super::contract::COCKPIT_VISIBILITY_SCHEMA_VERSION)
    );
    assert_eq!(overview["summary"]["totalOperations"], json!(188));
    assert_eq!(overview["summary"]["returnedOperations"], json!(188));
    assert_eq!(overview["summary"]["operationListComplete"], json!(true));
    assert_eq!(overview["summary"]["resourceScanComplete"], json!(true));
    assert_eq!(overview["operationList"]["totalOperations"], json!(188));
    assert_eq!(overview["operationList"]["returnedOperations"], json!(188));
    assert_eq!(overview["operationList"]["truncated"], json!(false));
    assert_eq!(overview["resourceScan"]["complete"], json!(true));
    assert_eq!(overview["resourceScan"]["truncated"], json!(false));
    assert_eq!(overview["summary"]["bindingRequests"], json!(1));
    assert_eq!(overview["summary"]["bindingRejected"], json!(1));
    assert_eq!(overview["summary"]["shadowRequests"], json!(1));
    assert_eq!(overview["summary"]["shadowRuns"], json!(1));
    assert!(super::cockpit_visibility::test_serialized_has_no_raw_cockpit_material(&overview));
    let names = super::cockpit_visibility::test_operation_names(&overview);
    assert!(names.contains("git_status"));
    assert!(names.contains("observe"));

    let git_status = operation_projection(&overview, "git_status");
    assert_eq!(git_status["owner"]["label"], json!("Built-in Git adapter"));
    assert_eq!(
        git_status["owner"]["metadataSourceLabel"],
        json!("Capability execute registry")
    );
    assert_eq!(
        git_status["owner"]["projectionSourceLabel"],
        json!("Capability binding cockpit projection")
    );
    assert!(git_status["owner"].get("backendOwner").is_none());
    assert_eq!(git_status["status"]["kind"], json!("built_in_adapter"));
    assert_eq!(git_status["replacement"]["canReplace"], json!(true));
    assert_eq!(
        git_status["replacement"]["target"]["label"],
        json!("Governed Git adapter")
    );
    assert_eq!(
        git_status["readiness"]["state"],
        json!("needs_governance_review")
    );
    assert_eq!(
        git_status["readiness"]["nextActionLabel"],
        json!("Inspect decisions")
    );
    assert_eq!(git_status["binding"]["requested"], json!(1));
    assert_eq!(git_status["binding"]["rejected"], json!(1));
    assert_eq!(git_status["binding"]["failedReplacementAttempts"], json!(1));
    assert_eq!(git_status["shadowTrial"]["requested"], json!(1));
    assert_eq!(git_status["shadowTrial"]["approved"], json!(1));
    assert_eq!(git_status["shadowTrial"]["runs"], json!(1));
    assert_eq!(git_status["shadowTrial"]["passed"], json!(1));
    assert_eq!(
        git_status["shadowTrial"]["availableForThisOperation"],
        json!(true)
    );
    assert_eq!(git_status["rollback"]["available"], json!(true));
    assert_eq!(git_status["rollback"]["disableAvailable"], json!(true));
    assert_eq!(git_status["rollback"]["abortAvailable"], json!(true));

    let observe = operation_projection(&overview, "observe");
    assert_eq!(observe["owner"]["label"], json!("Engine kernel"));
    assert_eq!(observe["status"]["kind"], json!("kernel_locked"));
    assert_eq!(observe["replacement"]["canReplace"], json!(false));
    assert_eq!(
        observe["replacement"]["target"]["label"],
        json!("Engine-owned kernel responsibility")
    );
    assert_eq!(
        observe["readiness"]["nextActionLabel"],
        json!("Observe only")
    );
    assert_eq!(observe["rollback"]["available"], json!(false));

    let goal_create = operation_projection(&overview, "goal_create");
    assert_eq!(goal_create["status"]["kind"], json!("record_plane"));
    assert_eq!(goal_create["replacement"]["canExtend"], json!(true));
    assert_eq!(goal_create["replacement"]["canReplace"], json!(false));

    let other_scope = cockpit_overview_value(
        &fixture.deps,
        &invocation(
            "cockpit-other-scope",
            json!({"limit": 200}),
            fixture.read_grant_id.clone(),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            "other-session",
        ),
    )
    .await
    .expect("other scope cockpit overview");
    let other_git_status = operation_projection(&other_scope, "git_status");
    assert_eq!(other_git_status["binding"]["requested"], json!(0));
    assert_eq!(other_git_status["shadowTrial"]["requested"], json!(0));
}

#[tokio::test]
async fn cockpit_overview_reports_operation_limit_and_bounded_resource_scan_truth() {
    let fixture = Fixture::new("capability-cockpit-truth").await;
    for index in 0..=100 {
        let key = format!("cockpit-truth-{index}");
        let request = fixture.binding_request(&key).await;
        assert_eq!(request["status"], json!("pending_review"));
    }

    let limited = cockpit_overview_value(
        &fixture.deps,
        &fixture.read_invocation("cockpit-overview-limit", json!({"limit": 1})),
    )
    .await
    .expect("limited cockpit overview");
    assert_eq!(limited["summary"]["totalOperations"], json!(188));
    assert_eq!(limited["summary"]["returnedOperations"], json!(1));
    assert_eq!(limited["summary"]["operationListComplete"], json!(false));
    assert_eq!(limited["summary"]["operationListTruncated"], json!(true));
    assert_eq!(limited["operationList"]["totalOperations"], json!(188));
    assert_eq!(limited["operationList"]["returnedOperations"], json!(1));
    assert_eq!(limited["operationList"]["requestedLimit"], json!(1));
    assert_eq!(limited["operationList"]["state"], json!("truncated"));
    assert_eq!(
        limited["operations"].as_array().expect("operations").len(),
        1
    );

    let full = cockpit_overview_value(
        &fixture.deps,
        &fixture.read_invocation("cockpit-overview-bounded-scan", json!({"limit": 200})),
    )
    .await
    .expect("bounded scan cockpit overview");
    assert_eq!(full["summary"]["totalOperations"], json!(188));
    assert_eq!(full["summary"]["returnedOperations"], json!(188));
    assert_eq!(full["summary"]["resourceScanComplete"], json!(false));
    assert_eq!(full["summary"]["resourceScanTruncated"], json!(true));
    assert_eq!(full["resourceScan"]["complete"], json!(false));
    assert_eq!(full["resourceScan"]["truncated"], json!(true));
    assert_eq!(full["resourceScan"]["truncatedQueries"], json!(1));
    assert_eq!(full["resourceScan"]["limitPerKindScope"], json!(100));
    assert_eq!(full["resourceScan"]["state"], json!("bounded_degraded"));
    assert_eq!(full["resourceScan"]["scannedResources"], json!(100));
    assert_eq!(full["resourceScan"]["appliedResources"], json!(100));

    let git_status = operation_projection(&full, "git_status");
    assert_eq!(git_status["binding"]["requested"], json!(100));
    assert!(
        full["resourceScan"]["detail"]
            .as_str()
            .expect("resource scan detail")
            .contains("lower-bound facts")
    );
    assert!(super::cockpit_visibility::test_serialized_has_no_raw_cockpit_material(&full));
    assert_eq!(full["projection"]["runtimeRoutingChanged"], json!(false));
    assert_eq!(full["projection"]["dispatchTableMutated"], json!(false));
    assert_eq!(full["projection"]["moduleActivated"], json!(false));
    assert_eq!(full["projection"]["moduleExecuted"], json!(false));
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

    let mut missing_disable = request_payload("missing-disable");
    missing_disable["disableRef"] = Value::Null;
    let invocation = fixture.write_invocation("missing-disable", missing_disable);
    let error = record_capability_binding_request_value_at(
        &fixture.deps,
        &invocation,
        &invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("disable ref required")
    .to_string();
    assert!(error.contains("disableRef"), "{error}");
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
        "replacementTarget": "future_git_adapter_requires_exact_repo_authority_head_index_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
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

fn shadow_request_payload(key: &str) -> Value {
    json!({
        "capabilityShadowTrialRequestId": format!("{key}-shadow-request"),
        "title": "Capability shadow trial request",
        "targetOperation": "git_status",
        "currentBuiltInOwner": "domains::capability::operations::git + domains::git",
        "replacementTarget": "future_git_adapter_requires_exact_repo_authority_head_index_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        "ownershipClass": "adapter_replaceable",
        "bindingMode": "shadow",
        "candidateAdapter": {
            "adapterId": "deterministic_git_status_shadow",
            "adapterVersion": "v1",
            "adapterKind": "deterministic_projection",
            "description": "Deterministic metadata-only status projection.",
            "executionMode": "metadata_only",
            "networkPolicy": "none",
            "moduleExecution": false,
            "packageManagerUsed": false,
            "runtimeRoutingEnabled": false,
            "agentStateInherited": false
        },
        "rationale": "Governed metadata trial records a deterministic projection without routing changes.",
        "contractEvidenceRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:shadow-contract",
            "role": "contract"
        }],
        "evidenceRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:shadow-scorecard",
            "role": "scorecard"
        }],
        "authorityConstraints": {
            "networkPolicy": "none",
            "authorityScopes": ["capability.execute", "git.read", "resource.read"],
            "resourceKinds": ["git_status_shadow_projection"],
            "resourceSelectors": ["resource:git_status_shadow_projection:current"],
            "agentStateInherited": false
        },
        "staleVersionGuard": {
            "expectedInventoryVersion": CAPABILITY_MODULARITY_INVENTORY_VERSION,
            "expectedPolicyVersion": CAPABILITY_BINDING_POLICY_VERSION
        },
        "rollbackRef": {
            "kind": "evidence",
            "resourceId": "evidence:shadow-rollback",
            "role": "rollback"
        },
        "disableRef": {
            "kind": "evidence",
            "resourceId": "evidence:shadow-disable",
            "role": "disable"
        },
        "abortRef": {
            "kind": "evidence",
            "resourceId": "evidence:shadow-abort",
            "role": "abort"
        },
        "auditRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:shadow-audit",
            "role": "audit"
        }]
    })
}

fn status_projection(status: &str) -> Value {
    json!({
        "operation": "git_status",
        "status": status,
        "headState": "known",
        "indexState": "known",
        "worktreeState": status,
        "truncation": "none",
        "evidenceRef": {
            "kind": "evidence",
            "resourceId": "evidence:status-projection",
            "role": "projection"
        }
    })
}

fn route_candidate_payload(
    key: &str,
    shadow_evidence_resource_id: &str,
    shadow_evidence_version_id: &str,
    module_lifecycle_ref: &Value,
    module_runtime_ref: &Value,
) -> Value {
    json!({
        "capabilityReplacementCandidateId": format!("{key}-replacement-candidate"),
        "targetOperation": "git_status",
        "currentBuiltInOwner": "domains::capability::operations::git + domains::git",
        "replacementTarget": "future_git_adapter_requires_exact_repo_authority_head_index_evidence_provider_safe_refs_replay_idempotency_and_rollback_disable_refs",
        "ownershipClass": "adapter_replaceable",
        "lifecycleState": "validated",
        "candidateLabel": "Governed repository state adapter",
        "candidateOwner": "module:git-status-shadow",
        "moduleRef": {
            "kind": "module_manifest",
            "resourceId": "module_manifest:git-status-shadow",
            "role": "module"
        },
        "moduleRuntimeRef": module_runtime_ref,
        "moduleLifecycleRef": module_lifecycle_ref,
        "shadowEvidenceRef": {
            "kind": CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
            "resourceId": shadow_evidence_resource_id,
            "versionId": shadow_evidence_version_id,
            "role": "shadow_evidence"
        },
        "contractEvidenceRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:route-contract",
            "role": "contract"
        }],
        "authorityConstraints": {
            "networkPolicy": "none",
            "authorityScopes": ["capability.execute", "git.read", "resource.read"],
            "resourceKinds": ["git_status_shadow_projection"],
            "resourceSelectors": ["resource:git_status_shadow_projection:current"],
            "agentStateInherited": false
        },
        "rollbackRef": {
            "kind": "evidence",
            "resourceId": "evidence:route-rollback",
            "role": "rollback"
        },
        "disableRef": {
            "kind": "evidence",
            "resourceId": "evidence:route-disable",
            "role": "disable"
        },
        "auditRefs": [{
            "kind": "evidence",
            "resourceId": "evidence:route-candidate-audit",
            "role": "audit"
        }]
    })
}

fn route_lifecycle_payload(scope: &EngineResourceScope, lifecycle_id: &str) -> Value {
    json!({
        "schemaVersion": "tron.module_lifecycle_state.v1",
        "state": "enabled",
        "transitionId": "route-lifecycle-enabled",
        "scope": {"kind": scope.kind(), "value": scope.value()},
        "installDecision": {
            "kind": "module_install_decision",
            "resourceId": format!("module_install_decision:{lifecycle_id}"),
            "role": "install_decision",
            "lifecycle": "approved"
        },
        "transition": {
            "action": "enable",
            "from": null,
            "to": "enabled",
            "reason": "Route fixture enables a supervised adapter.",
            "metadataOnly": true,
            "stateMutationOnly": true,
            "activationPerformed": false,
            "executionPerformed": false,
            "rollbackExecuted": false
        },
        "previous": {
            "state": null,
            "versionId": null,
            "currentVersionRevalidated": false
        },
        "approval": {
            "decision": "approved",
            "evidenceOnly": true,
            "approvalIsAuthority": false
        },
        "rollback": {
            "proofRefs": [],
            "status": "ready",
            "metadataOnly": true,
            "rollbackExecuted": false
        },
        "runtimeAuthorization": {
            "failClosed": true,
            "enabledAllowsRuntime": true,
            "disabledDenied": true,
            "quarantinedDenied": true,
            "rolledBackDenied": true
        },
        "evidenceRefs": [],
        "traceRefs": [],
        "replayRefs": [],
        "authority": {
            "grantRedacted": true,
            "rawAuthorityIdsStored": false,
            "derivedRuntimeGrantRequired": true,
            "approvalEvidenceIsAuthority": false,
            "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
            "resourceKinds": [MODULE_LIFECYCLE_STATE_KIND],
            "wildcardGrantsAllowed": false
        },
        "idempotency": {
            "fingerprint": "route-lifecycle-fixture",
            "fingerprintAlgorithm": "sha256:tron.module_lifecycle_state.idempotency.v1",
            "keyRedacted": true,
            "rawKeyStored": false
        },
        "sideEffectProof": {
            "metadataOnly": true,
            "installPerformed": false,
            "activationPerformed": false,
            "executionPerformed": false,
            "rollbackExecuted": false,
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "networkPolicy": "none",
            "networkAccessPerformed": false,
            "repoManagedSkillsTouched": false,
            "physicalWorkspaceDirectoryCreated": false,
            "rawCommandsStored": false,
            "rawLogsStored": false,
            "fileContentsStored": false,
            "absolutePathsStored": false
        },
        "createdAt": DEFAULT_OPERATION_AT,
        "updatedAt": DEFAULT_OPERATION_AT,
        "revision": 1
    })
}

fn route_runtime_payload(
    scope: &EngineResourceScope,
    lifecycle_id: &str,
    lifecycle_version_id: &str,
    key: &str,
) -> Value {
    json!({
        "schemaVersion": "tron.module_runtime_state.v1",
        "state": "running",
        "runtimeRequestId": format!("{key}-runtime-request"),
        "scope": {"kind": scope.kind(), "value": scope.value()},
        "moduleLifecycle": {
            "allowed": true,
            "state": "enabled",
            "resourceId": lifecycle_id,
            "versionId": lifecycle_version_id,
            "runtimeAuthorization": {
                "failClosed": true,
                "enabledAllowsRuntime": true
            }
        },
        "runtime": {
            "kind": "git_status_adapter",
            "label": "Repository state adapter",
            "featureSemanticsOwnedByPackage": true,
            "supervisorEnvelopeOnly": true,
            "processLaunched": false,
            "jobDelegated": false,
            "jobExposedToProvider": false
        },
        "supervision": {
            "state": "running",
            "sandbox": {"label": "metadata_only", "pty": false, "browserAutomation": false},
            "network": {"policy": "none", "accessPerformed": false},
            "secrets": {"available": false, "rawValuesStored": false},
            "timeout": {"timeoutMs": 30000, "state": "armed"},
            "cancellation": {"state": "not_requested", "cancelRequested": false},
            "shutdown": {"state": "cancel_on_shutdown", "recorded": true}
        },
        "inputRefs": [],
        "outputArtifactRefs": [],
        "evidenceRefs": [],
        "traceRefs": [],
        "replayRefs": [],
        "authority": {
            "grantRedacted": true,
            "rawAuthorityIdsStored": false,
            "derivedRuntimeGrantRequired": true,
            "lifecycleAuthorizationRequired": true,
            "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
            "resourceKinds": [MODULE_RUNTIME_STATE_KIND, MODULE_LIFECYCLE_STATE_KIND],
            "wildcardGrantsAllowed": false
        },
        "idempotency": {
            "fingerprint": "route-runtime-fixture",
            "fingerprintAlgorithm": "sha256:tron.module_runtime_state.idempotency.v1",
            "keyRedacted": true,
            "rawKeyStored": false
        },
        "sideEffectProof": {
            "supervisorEnvelopeOnly": true,
            "installPerformed": false,
            "activationPerformed": false,
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "networkPolicy": "none",
            "networkAccessPerformed": false,
            "repoManagedSkillsTouched": false,
            "physicalWorkspaceDirectoryCreated": false,
            "ptyAllocated": false,
            "browserAutomationPerformed": false,
            "rawCommandsStored": false,
            "rawLogsStored": false,
            "rawOutputStored": false,
            "secretsExposed": false,
            "fileContentsStored": false,
            "absolutePathsStored": false
        },
        "reason": "Route fixture supervised runtime envelope.",
        "createdAt": DEFAULT_OPERATION_AT,
        "updatedAt": DEFAULT_OPERATION_AT,
        "revision": 1
    })
}

fn synthetic_lifecycle_ref(key: &str) -> Value {
    json!({
        "kind": MODULE_LIFECYCLE_STATE_KIND,
        "resourceId": format!("module_lifecycle_state:{key}"),
        "versionId": format!("version-{key}"),
        "role": "lifecycle"
    })
}

fn synthetic_runtime_ref(key: &str) -> Value {
    json!({
        "kind": MODULE_RUNTIME_STATE_KIND,
        "resourceId": format!("module_runtime_state:{key}"),
        "versionId": format!("version-{key}"),
        "role": "runtime"
    })
}

fn shadow_trial_kinds() -> [&'static str; 4] {
    [
        CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
        CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
        CAPABILITY_SHADOW_TRIAL_RUN_KIND,
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
    ]
}

fn shadow_trial_kind_selectors() -> Vec<String> {
    shadow_trial_kinds()
        .iter()
        .map(|kind| format!("kind:{kind}"))
        .collect()
}

fn route_kinds() -> [&'static str; 12] {
    [
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
        CAPABILITY_ROUTE_BINDING_KIND,
        CAPABILITY_ROUTE_ACTIVATION_KIND,
        CAPABILITY_ROUTE_EVENT_KIND,
        CAPABILITY_ROUTE_ROLLBACK_KIND,
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
        CAPABILITY_SHADOW_TRIAL_RUN_KIND,
        CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
        CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
        CAPABILITY_BINDING_POLICY_KIND,
        MODULE_LIFECYCLE_STATE_KIND,
        MODULE_RUNTIME_STATE_KIND,
    ]
}

fn route_kind_selectors() -> Vec<String> {
    route_kinds()
        .iter()
        .map(|kind| format!("kind:{kind}"))
        .collect()
}

fn operation_projection<'a>(overview: &'a Value, operation_name: &str) -> &'a Value {
    overview["operations"]
        .as_array()
        .expect("operations array")
        .iter()
        .find(|operation| operation["name"] == json!(operation_name))
        .unwrap_or_else(|| panic!("missing operation projection for {operation_name}"))
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

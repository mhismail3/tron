use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    inspect_request_value, inspect_review_value, inspect_source_value, list_request_value,
    list_review_value, list_source_value, record_request_value_at, record_review_value_at,
    record_source_value_at,
};
use super::{
    Deps, WEB_RESEARCH_REQUEST_KIND, WEB_RESEARCH_REQUEST_SCHEMA_ID, WEB_RESEARCH_REVIEW_KIND,
    WEB_RESEARCH_REVIEW_SCHEMA_ID, WEB_RESEARCH_SOURCE_KIND, WEB_RESEARCH_SOURCE_SCHEMA_ID,
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
                WEB_RESEARCH_REQUEST_KIND,
                WEB_RESEARCH_REVIEW_KIND,
                WEB_RESEARCH_SOURCE_KIND,
            ],
            &[
                "kind:web_research_request",
                "kind:web_research_review",
                "kind:web_research_source",
            ],
            "none",
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[
                WEB_RESEARCH_REQUEST_KIND,
                WEB_RESEARCH_REVIEW_KIND,
                WEB_RESEARCH_SOURCE_KIND,
            ],
            &[
                "kind:web_research_request",
                "kind:web_research_review",
                "kind:web_research_source",
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

    async fn request(&self, key: &str) -> Value {
        let invocation = self.write_invocation(key, request_payload(key));
        record_request_value_at(
            &self.deps,
            &invocation,
            &invocation.payload,
            default_operation_at(),
        )
        .await
        .expect("record request")
    }

    async fn exact_read_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        self.exact_grant(suffix, &[READ_SCOPE, RESOURCE_READ_SCOPE], resource_id)
            .await
    }

    async fn exact_write_grant(&self, suffix: &str, resource_id: &str) -> AuthorityGrantId {
        self.exact_grant(
            suffix,
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            resource_id,
        )
        .await
    }

    async fn exact_grant(
        &self,
        suffix: &str,
        scopes: &[&str],
        resource_id: &str,
    ) -> AuthorityGrantId {
        let exact_selector = format!("resource:{resource_id}");
        derive_grant(
            &self.deps,
            suffix,
            scopes,
            &[
                WEB_RESEARCH_REQUEST_KIND,
                WEB_RESEARCH_REVIEW_KIND,
                WEB_RESEARCH_SOURCE_KIND,
            ],
            &[
                "kind:web_research_request",
                "kind:web_research_review",
                "kind:web_research_source",
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
fn web_research_resource_types_are_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    for (kind, schema_id) in [
        (WEB_RESEARCH_REQUEST_KIND, WEB_RESEARCH_REQUEST_SCHEMA_ID),
        (WEB_RESEARCH_REVIEW_KIND, WEB_RESEARCH_REVIEW_SCHEMA_ID),
        (WEB_RESEARCH_SOURCE_KIND, WEB_RESEARCH_SOURCE_SCHEMA_ID),
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.kind == kind)
            .expect("web research definition");
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
            definition.materialization_rules["browserAutomation"],
            json!("forbidden")
        );
        assert_eq!(definition.redaction_rules["rawHtml"], json!("forbidden"));
    }
}

#[tokio::test]
async fn request_review_source_record_list_inspect_and_replay_are_provider_safe() {
    let fixture = Fixture::new("web-research-flow").await;
    let request = fixture.request("request").await;
    assert_eq!(request["status"], json!("pending_review"));
    assert_eq!(request["idempotentReplay"], json!(false));
    assert_eq!(
        request["request"]["research"]["networkPolicy"],
        json!("none")
    );
    let replay = fixture.request("request").await;
    assert_eq!(replay["idempotentReplay"], json!(true));
    let request_id = request["webResearchRequestResourceId"]
        .as_str()
        .expect("request id");

    let review_grant = fixture
        .exact_write_grant("review-request-exact", request_id)
        .await;
    let review_invocation = invocation(
        "review",
        json!({
            "webResearchRequestResourceId": request_id,
            "webResearchReviewId": "review-one",
            "reviewOutcome": "pending_review",
            "reviewSummary": "Independent review is still pending for the metadata-only web research module pack.",
            "policyLabels": ["pending_review", "implementation-candidate"],
            "evidenceRefs": [{"kind": "phase3_inventory", "resourceId": "P3MSA-INV-014", "role": "evidence"}]
        }),
        review_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let review = record_review_value_at(
        &fixture.deps,
        &review_invocation,
        &review_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record review");
    let review_id = review["webResearchReviewResourceId"]
        .as_str()
        .expect("review id");

    let source_grant = derive_grant(
        &fixture.deps,
        "source-both-exact",
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &[
            WEB_RESEARCH_REQUEST_KIND,
            WEB_RESEARCH_REVIEW_KIND,
            WEB_RESEARCH_SOURCE_KIND,
        ],
        &[
            "kind:web_research_request",
            "kind:web_research_review",
            "kind:web_research_source",
            &format!("resource:{request_id}"),
            &format!("resource:{review_id}"),
        ],
        "none",
    )
    .await;
    let source_invocation = invocation(
        "source",
        json!({
            "webResearchRequestResourceId": request_id,
            "webResearchReviewResourceId": review_id,
            "webResearchSourceId": "source-one",
            "artifactKind": "citation_set",
            "title": "Bounded citation source refs",
            "summary": "Citation artifacts contain refs and short summaries only.",
            "sourceRefs": [{"kind": "web_source", "resourceId": "web_source:bounded", "role": "source"}],
            "citationRefs": [{"kind": "citation", "resourceId": "citation:bounded", "role": "citation"}],
            "robotsEvidenceRefs": [{"kind": "web_robots_policy", "resourceId": "web_robots_policy:bounded", "role": "robots"}]
        }),
        source_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let source = record_source_value_at(
        &fixture.deps,
        &source_invocation,
        &source_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect("record source");
    let source_id = source["webResearchSourceResourceId"]
        .as_str()
        .expect("source id");
    assert_eq!(source["source"]["artifact"]["rawHtmlStored"], json!(false));

    assert_eq!(
        list_request_value(
            &fixture.deps,
            &fixture.read_invocation("list-requests", json!({})),
            &json!({})
        )
        .await
        .expect("list requests")["requests"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        list_review_value(
            &fixture.deps,
            &fixture.read_invocation("list-reviews", json!({})),
            &json!({})
        )
        .await
        .expect("list reviews")["reviews"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        list_source_value(
            &fixture.deps,
            &fixture.read_invocation("list-sources", json!({})),
            &json!({})
        )
        .await
        .expect("list sources")["sources"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let request_grant = fixture.exact_read_grant("request-exact", request_id).await;
    let inspected_request = inspect_request_value(
        &fixture.deps,
        &invocation(
            "inspect-request",
            json!({"webResearchRequestResourceId": request_id}),
            request_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"webResearchRequestResourceId": request_id}),
    )
    .await
    .expect("inspect request");
    assert_eq!(
        inspected_request["request"]["sideEffectProof"]["networkPolicy"],
        json!("none")
    );

    let review_grant = fixture.exact_read_grant("review-exact", review_id).await;
    let inspected_review = inspect_review_value(
        &fixture.deps,
        &invocation(
            "inspect-review",
            json!({"webResearchReviewResourceId": review_id}),
            review_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"webResearchReviewResourceId": review_id}),
    )
    .await
    .expect("inspect review");
    assert_eq!(
        inspected_review["review"]["review"]["review"]["metadataOnly"],
        json!(true)
    );

    let source_grant = fixture.exact_read_grant("source-exact", source_id).await;
    let inspected_source = inspect_source_value(
        &fixture.deps,
        &invocation(
            "inspect-source",
            json!({"webResearchSourceResourceId": source_id}),
            source_grant,
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &fixture.session_id,
        ),
        &json!({"webResearchSourceResourceId": source_id}),
    )
    .await
    .expect("inspect source");
    assert_eq!(
        inspected_source["source"]["source"]["artifact"]["cookiesStored"],
        json!(false)
    );
}

#[tokio::test]
async fn unsafe_payloads_network_policy_and_missing_exact_selectors_are_rejected() {
    let fixture = Fixture::new("web-research-unsafe").await;
    for payload in [
        {
            let mut payload = request_payload("raw-html");
            payload["rawHtml"] = json!("<html>raw page body</html>");
            payload
        },
        {
            let mut payload = request_payload("cookie");
            payload["cookies"] = json!("session=value");
            payload
        },
        {
            let mut payload = request_payload("local-path");
            payload["questionSummary"] = json!("Inspect /Users/example/web/profile directly");
            payload
        },
    ] {
        let invocation = fixture.write_invocation("unsafe", payload);
        let error = record_request_value_at(
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
                || error.contains("credential-like")
                || error.contains("path-like"),
            "unexpected error: {error}"
        );
    }

    let network_grant = derive_grant(
        &fixture.deps,
        "network-declared",
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &[
            WEB_RESEARCH_REQUEST_KIND,
            WEB_RESEARCH_REVIEW_KIND,
            WEB_RESEARCH_SOURCE_KIND,
        ],
        &[
            "kind:web_research_request",
            "kind:web_research_review",
            "kind:web_research_source",
        ],
        "declared",
    )
    .await;
    let network_invocation = invocation(
        "network",
        request_payload("network"),
        network_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = record_request_value_at(
        &fixture.deps,
        &network_invocation,
        &network_invocation.payload,
        default_operation_at(),
    )
    .await
    .expect_err("network policy none required")
    .to_string();
    assert!(error.contains("networkPolicy none"));

    let request = fixture.request("selector").await;
    let request_id = request["webResearchRequestResourceId"].as_str().unwrap();
    let selector_denied = inspect_request_value(
        &fixture.deps,
        &fixture.read_invocation(
            "selector-denied",
            json!({"webResearchRequestResourceId": request_id}),
        ),
        &json!({"webResearchRequestResourceId": request_id}),
    )
    .await
    .expect_err("exact selector required")
    .to_string();
    assert!(selector_denied.contains("exact resource:"));

    let review_without_selector = record_review_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "review-denied",
            json!({
                "webResearchRequestResourceId": request_id,
                "reviewSummary": "Review must fail without exact request selector."
            }),
        ),
        &json!({
            "webResearchRequestResourceId": request_id,
            "reviewSummary": "Review must fail without exact request selector."
        }),
        default_operation_at(),
    )
    .await
    .expect_err("linked review exact selector required")
    .to_string();
    assert!(review_without_selector.contains("exact resource:"));
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
            grant_id: Some(AuthorityGrantId::new(format!("web-research-{label}")).unwrap()),
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
            budget: json!({"class": "web_research_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"test": label}),
            trace_id: TraceId::new(format!("trace-web-research-{label}")).expect("trace id"),
        })
        .await
        .expect("derive grant")
        .grant_id
}

fn request_payload(key: &str) -> Value {
    json!({
        "webResearchRequestId": format!("{key}-web-research-request"),
        "title": "Web research request",
        "questionSummary": "Capture a bounded research question without browser automation or network access.",
        "scopeSummary": "Current session scope only; direct fetching remains in the web domain.",
        "policyLabels": ["pending_review", "network-none"],
        "sourceRefs": [{"kind": "web_source", "resourceId": "web_source:bounded", "role": "source"}],
        "citationRefs": [{"kind": "citation", "resourceId": "citation:bounded", "role": "citation"}],
        "robotsEvidenceRefs": [{"kind": "web_robots_policy", "resourceId": "web_robots_policy:bounded", "role": "robots"}],
        "dependencyRequestRefs": [{"kind": "module_dependency_request", "resourceId": "module_dependency_request:bounded", "role": "dependency_review"}],
        "currentScopeRefs": [{"kind": "session", "resourceId": "session:bounded", "role": "scope"}],
        "evidenceRefs": [{"kind": "phase3_inventory", "resourceId": "P3MSA-INV-014", "role": "evidence"}]
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

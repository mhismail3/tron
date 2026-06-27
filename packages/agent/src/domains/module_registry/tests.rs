use serde_json::{Value, json};

use super::manifest::LIST_LIMIT_MAX;
use super::service::{inspect_module_value, list_modules_value};
use super::{MODULE_MANIFEST_KIND, MODULE_MANIFEST_SCHEMA_ID, READ_SCOPE, SCHEMA_VERSION, WORKER};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, WorkerId,
};
use crate::engine::kernel::types::RiskLevel;
use crate::engine::{
    ActorKind, CausalContext, CreateResource, DeliveryMode, DeriveGrant, EngineHostHandle,
    EngineResourceScope, EngineResourceVersioningMode, ListResources, RegisterResourceType,
};

const RESOURCE_READ_SCOPE: &str = "resource.read";

#[tokio::test]
async fn built_in_definition_and_seed_resources_are_registered() {
    let definitions = crate::engine::builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == MODULE_MANIFEST_KIND)
        .expect("module manifest type definition");

    assert_eq!(definition.schema_id, MODULE_MANIFEST_SCHEMA_ID);
    assert_eq!(
        definition.lifecycle_states,
        vec!["candidate", "validated", "stale", "archived"]
    );
    assert_eq!(definition.owner_worker_id.as_str(), WORKER);
    assert_eq!(
        definition.required_capabilities["read"],
        json!([READ_SCOPE, RESOURCE_READ_SCOPE])
    );

    let host = EngineHostHandle::new_in_memory().expect("engine host");
    for resource_id in [
        "module_manifest:module_registry",
        "module_manifest:capability",
        "module_manifest:file_git_module",
        "module_manifest:jobs_program_execution_module",
    ] {
        let inspection = host
            .inspect_resource(resource_id)
            .await
            .expect("inspect seed")
            .expect("seed exists");
        assert_eq!(inspection.resource.kind, MODULE_MANIFEST_KIND);
        assert_eq!(inspection.resource.schema_id, MODULE_MANIFEST_SCHEMA_ID);
        assert_eq!(inspection.resource.scope, EngineResourceScope::System);
        assert_eq!(inspection.resource.lifecycle, "validated");
        assert_eq!(
            inspection.versions[0].payload["schemaVersion"],
            json!(SCHEMA_VERSION)
        );
    }
}

#[tokio::test]
async fn jobs_program_execution_module_manifest_projects_ref_only_pending_review_metadata() {
    let host = EngineHostHandle::new_in_memory().expect("engine host");
    let grant_id = derive_module_read_grant(
        &host,
        "jobs-program-execution-module",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &[
            "kind:module_manifest",
            "resource:module_manifest:jobs_program_execution_module",
        ],
        "none",
    )
    .await;

    let inspect_invocation = module_invocation(
        "jobs-program-execution-module",
        json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": "module_manifest:jobs_program_execution_module",
            "maxItems": 1000
        }),
        grant_id,
    );
    let inspected = inspect_module_value(&host, &inspect_invocation, &inspect_invocation.payload)
        .await
        .expect("inspect jobs/program execution module");
    let resource = &inspected["resource"];

    assert_eq!(
        resource["identity"]["moduleId"]["text"],
        json!("jobs_program_execution_module")
    );
    assert_eq!(resource["identity"]["kind"]["text"], json!("module_pack"));
    assert_eq!(
        resource["manifestLifecycle"]["state"]["text"],
        json!("pending_review")
    );
    assert_eq!(
        resource["manifestLifecycle"]["activation"]["text"],
        json!("authority_mapped_module_pack")
    );
    assert_eq!(resource["manifestLifecycle"]["executable"], json!(false));
    assert_eq!(
        resource["validation"]["status"]["text"],
        json!("pending_review")
    );
    assert_eq!(resource["capabilityDeclarations"]["total"], json!(4));
    assert_eq!(resource["resourceDeclarations"]["total"], json!(5));
    assert_eq!(resource["authorityNeeds"]["total"], json!(8));
    assert_side_effects_are_absent(&inspected);
    assert_provider_projection_has_no_raw_sensitive_material(&inspected);

    let declared_operations = resource["capabilityDeclarations"]["items"]
        .as_array()
        .expect("capability declarations")
        .iter()
        .filter_map(|item| item.pointer("/operation/text").and_then(Value::as_str))
        .collect::<Vec<_>>();
    assert_eq!(
        declared_operations,
        vec![
            "module_program_execution_start",
            "module_program_execution_status",
            "module_program_execution_cancel",
            "module_program_execution_cleanup",
        ]
    );
    let rendered = serde_json::to_string(&inspected).expect("serialize module projection");
    for operation in [
        "module_program_execution_start",
        "module_program_execution_status",
        "module_program_execution_cancel",
        "module_program_execution_cleanup",
    ] {
        assert!(
            rendered.contains(operation),
            "missing operation {operation}"
        );
    }
    for resource_kind in [
        "module_runtime_state",
        "module_lifecycle_state",
        "program_execution_record",
        "job_process",
        "execution_output",
    ] {
        assert!(
            rendered.contains(resource_kind),
            "missing resource kind {resource_kind}"
        );
    }
    for rejected in ["job_start", "job_log", "stdoutPreview", "stderrPreview"] {
        assert!(
            !rendered.contains(rejected),
            "leaked rejected jobs/program-execution material {rejected}"
        );
    }
}

#[tokio::test]
async fn list_and_inspect_return_bounded_provider_safe_projections() {
    let host = EngineHostHandle::new_in_memory().expect("engine host");
    let grant_id = derive_module_read_grant(
        &host,
        "safe-projection",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &[
            "kind:module_manifest",
            "resource:module_manifest:module_registry",
        ],
        "none",
    )
    .await;

    let list_invocation = module_invocation(
        "safe-list",
        json!({"operation": "module_list", "limit": LIST_LIMIT_MAX + 10}),
        grant_id.clone(),
    );
    let listed = list_modules_value(&host, &list_invocation, &list_invocation.payload)
        .await
        .expect("list modules");
    assert_eq!(listed["schemaVersion"], json!(SCHEMA_VERSION));
    assert_eq!(listed["operation"], json!("module_list"));
    assert!(listed["modules"].as_array().expect("modules").len() <= LIST_LIMIT_MAX);
    assert_side_effects_are_absent(&listed);
    assert!(listed["redacted"].as_bool().expect("redacted"));

    let inspect_invocation = module_invocation(
        "safe-inspect",
        json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": "module_manifest:module_registry",
            "maxItems": 200
        }),
        grant_id,
    );
    let inspected = inspect_module_value(&host, &inspect_invocation, &inspect_invocation.payload)
        .await
        .expect("inspect module");
    assert_eq!(inspected["schemaVersion"], json!(SCHEMA_VERSION));
    assert_eq!(inspected["operation"], json!("module_inspect"));
    assert_eq!(inspected["limits"]["maxItems"], json!(100));
    assert_side_effects_are_absent(&inspected);
    assert!(inspected["redacted"].as_bool().expect("redacted"));

    let resource = &inspected["resource"];
    for field in [
        "identity",
        "capabilityDeclarations",
        "resourceDeclarations",
        "authorityNeeds",
        "settingsDeclarations",
        "dependencyIntents",
        "validation",
        "provenance",
        "resourceLifecycle",
        "manifestLifecycle",
        "redactionProof",
        "redaction",
    ] {
        assert!(
            resource.get(field).is_some(),
            "missing provider projection {field}"
        );
    }
    assert!(
        resource.get("payload").is_none(),
        "raw manifest payload must not be provider visible"
    );
    assert_eq!(resource["resourceLifecycle"], json!("validated"));
    assert_eq!(
        resource["manifestLifecycle"]["state"]["text"],
        json!("validated")
    );
    assert_provider_projection_has_no_raw_sensitive_material(&inspected);
}

#[tokio::test]
async fn file_git_module_manifest_projects_bounded_pending_review_metadata() {
    let host = EngineHostHandle::new_in_memory().expect("engine host");
    let grant_id = derive_module_read_grant(
        &host,
        "file-git-module",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &[
            "kind:module_manifest",
            "resource:module_manifest:file_git_module",
        ],
        "none",
    )
    .await;

    let inspect_invocation = module_invocation(
        "file-git-module",
        json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": "module_manifest:file_git_module",
            "maxItems": 1000
        }),
        grant_id,
    );
    let inspected = inspect_module_value(&host, &inspect_invocation, &inspect_invocation.payload)
        .await
        .expect("inspect file/git module");
    let resource = &inspected["resource"];

    assert_eq!(
        resource["identity"]["moduleId"]["text"],
        json!("file_git_module")
    );
    assert_eq!(resource["identity"]["kind"]["text"], json!("module_pack"));
    assert_eq!(
        resource["manifestLifecycle"]["state"]["text"],
        json!("pending_review")
    );
    assert_eq!(
        resource["manifestLifecycle"]["activation"]["text"],
        json!("authority_mapped_module_pack")
    );
    assert_eq!(resource["capabilityDeclarations"]["total"], json!(16));
    assert_eq!(resource["resourceDeclarations"]["total"], json!(5));
    assert_eq!(resource["authorityNeeds"]["total"], json!(6));
    assert_eq!(resource["capabilityDeclarations"]["maxItems"], json!(100));
    assert_side_effects_are_absent(&inspected);
    assert_provider_projection_has_no_raw_sensitive_material(&inspected);

    let rendered = serde_json::to_string(&inspected).expect("serialize file/git projection");
    for operation in [
        "filesystem_read",
        "filesystem_write",
        "git_status",
        "git_diff",
        "git_branch_inventory",
        "git_stage",
        "git_unstage",
        "git_commit",
        "git_branch_start",
    ] {
        assert!(
            rendered.contains(operation),
            "missing operation {operation}"
        );
    }
    for rejected in [
        "git_checkout",
        "git_merge",
        "git_rebase",
        "git_reset",
        "git_stash",
        "git_fetch",
        "git_pull",
        "git_push",
    ] {
        assert!(
            !rendered.contains(rejected),
            "leaked rejected operation {rejected}"
        );
    }
}

#[tokio::test]
async fn stored_kind_schema_scope_lifecycle_and_missing_ids_are_revalidated() {
    let host = EngineHostHandle::new_in_memory().expect("engine host");
    let grant_id = derive_module_read_grant(
        &host,
        "store-revalidation",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &["kind:module_manifest"],
        "none",
    )
    .await;

    register_lax_type(
        &host,
        "not_module_manifest",
        "tron.resource.not_module_manifest.v1",
    )
    .await;
    create_resource(
        &host,
        "module_manifest:wrong-kind",
        "not_module_manifest",
        None,
        EngineResourceScope::System,
        json!({"safe": true}),
        "available",
    )
    .await;
    let wrong_kind = inspect_with_resource(&host, grant_id.clone(), "wrong-kind")
        .await
        .expect_err("wrong kind denied")
        .to_string();
    assert!(
        wrong_kind.contains("expected module_manifest"),
        "{wrong_kind}"
    );

    let wrong_schema_host = EngineHostHandle::new_in_memory().expect("wrong schema host");
    wrong_schema_host
        .register_resource_type(RegisterResourceType {
            kind: MODULE_MANIFEST_KIND.to_owned(),
            schema_id: "tron.resource.module_manifest.untrusted.v1".to_owned(),
            schema: json!({"type": "object"}),
            lifecycle_states: ["candidate", "validated", "stale", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: Vec::new(),
            default_retention: json!({"class": "module_registry_manifest"}),
            redaction_rules: json!({"projection": "provider_safe"}),
            materialization_rules: json!({"activation": "forbidden"}),
            required_capabilities: json!({"read": [READ_SCOPE, RESOURCE_READ_SCOPE]}),
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
        })
        .await
        .expect("register wrong module schema");
    create_resource(
        &wrong_schema_host,
        "module_manifest:wrong-schema",
        MODULE_MANIFEST_KIND,
        None,
        EngineResourceScope::System,
        valid_manifest_payload("wrong_schema"),
        "validated",
    )
    .await;
    let wrong_schema_grant = derive_module_read_grant(
        &wrong_schema_host,
        "wrong-schema",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &["kind:module_manifest"],
        "none",
    )
    .await;
    let wrong_schema = inspect_with_resource_on(
        &wrong_schema_host,
        wrong_schema_grant,
        "wrong-schema",
        "module_manifest:wrong-schema",
    )
    .await
    .expect_err("wrong schema denied")
    .to_string();
    assert!(
        wrong_schema.contains("expected schema tron.resource.module_manifest.v1"),
        "{wrong_schema}"
    );

    create_module_manifest_resource(
        &host,
        "module_manifest:wrong-scope",
        EngineResourceScope::Workspace("module-registry-test-workspace".to_owned()),
        valid_manifest_payload("wrong_scope"),
        "validated",
    )
    .await;
    let wrong_scope = inspect_with_resource(&host, grant_id.clone(), "wrong-scope")
        .await
        .expect_err("wrong scope denied")
        .to_string();
    assert!(
        wrong_scope.contains("outside system scope"),
        "{wrong_scope}"
    );

    create_module_manifest_resource(
        &host,
        "module_manifest:archived",
        EngineResourceScope::System,
        valid_manifest_payload("archived"),
        "archived",
    )
    .await;
    let archived = inspect_with_resource(&host, grant_id.clone(), "archived")
        .await
        .expect_err("archived denied")
        .to_string();
    assert!(archived.contains("lifecycle archived"), "{archived}");

    let missing = inspect_with_resource(&host, grant_id, "missing")
        .await
        .expect_err("missing id denied")
        .to_string();
    assert!(missing.contains("missing module manifest"), "{missing}");
}

#[tokio::test]
async fn read_authority_must_be_explicit_and_module_manifest_scoped() {
    let host = EngineHostHandle::new_in_memory().expect("engine host");

    let missing_grant_invocation = module_invocation(
        "missing-grant",
        json!({"operation": "module_list"}),
        AuthorityGrantId::new("module-registry-missing-grant").unwrap(),
    );
    let missing = list_modules_value(
        &host,
        &missing_grant_invocation,
        &missing_grant_invocation.payload,
    )
    .await
    .expect_err("missing grant denied")
    .to_string();
    assert!(
        missing.contains("authority grant was not found"),
        "{missing}"
    );

    let wildcard_selector_grant = derive_module_read_grant(
        &host,
        "wildcard-selector",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &["*", "kind:module_manifest"],
        "none",
    )
    .await;
    let wildcard_selector_invocation = module_invocation(
        "wildcard-selector",
        json!({"operation": "module_list"}),
        wildcard_selector_grant,
    );
    let wildcard_selector = list_modules_value(
        &host,
        &wildcard_selector_invocation,
        &wildcard_selector_invocation.payload,
    )
    .await
    .expect_err("wildcard selector denied")
    .to_string();
    assert!(
        wildcard_selector.contains("wildcard grants are not accepted"),
        "{wildcard_selector}"
    );

    let wrong_kind_grant = derive_module_read_grant(
        &host,
        "wrong-resource-kind",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &["web_source"],
        &["kind:module_manifest"],
        "none",
    )
    .await;
    let wrong_kind_invocation = module_invocation(
        "wrong-resource-kind",
        json!({"operation": "module_list"}),
        wrong_kind_grant,
    );
    let wrong_kind = list_modules_value(
        &host,
        &wrong_kind_invocation,
        &wrong_kind_invocation.payload,
    )
    .await
    .expect_err("wrong resource kind denied")
    .to_string();
    assert!(
        wrong_kind.contains("requires module_manifest authority"),
        "{wrong_kind}"
    );
}

#[tokio::test]
async fn list_and_inspect_have_no_resource_side_effects() {
    let host = EngineHostHandle::new_in_memory().expect("engine host");
    let grant_id = derive_module_read_grant(
        &host,
        "side-effects",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[MODULE_MANIFEST_KIND],
        &[
            "kind:module_manifest",
            "resource:module_manifest:module_registry",
        ],
        "none",
    )
    .await;
    let before = list_all_module_manifest_count(&host).await;

    let list_invocation = module_invocation(
        "side-effects-list",
        json!({"operation": "module_list"}),
        grant_id.clone(),
    );
    list_modules_value(&host, &list_invocation, &list_invocation.payload)
        .await
        .expect("list modules");
    let after_list = list_all_module_manifest_count(&host).await;
    assert_eq!(after_list, before, "module_list must not write resources");

    let inspect_invocation = module_invocation(
        "side-effects-inspect",
        json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": "module_manifest:module_registry"
        }),
        grant_id,
    );
    inspect_module_value(&host, &inspect_invocation, &inspect_invocation.payload)
        .await
        .expect("inspect module");
    let after_inspect = list_all_module_manifest_count(&host).await;
    assert_eq!(
        after_inspect, before,
        "module_inspect must not write resources"
    );
}

async fn derive_module_read_grant(
    host: &EngineHostHandle,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    host.derive_authority_grant(DeriveGrant {
        grant_id: Some(AuthorityGrantId::new(format!("module-registry-read-{suffix}")).unwrap()),
        parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
        subject_actor_id: None,
        subject_worker_id: None,
        subject_invocation_id: None,
        allowed_capabilities: vec!["capability::execute".to_owned()],
        allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
        allowed_authority_scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
        allowed_resource_kinds: resource_kinds
            .iter()
            .map(|kind| (*kind).to_owned())
            .collect(),
        resource_selectors: selectors
            .iter()
            .map(|selector| (*selector).to_owned())
            .collect(),
        file_roots: vec!["/tmp".to_owned()],
        network_policy: network_policy.to_owned(),
        max_risk: RiskLevel::Low,
        budget: json!({"class": "module_registry_read_test"}),
        expires_at: None,
        can_delegate: false,
        provenance: json!({"source": "module_registry_test"}),
        trace_id: TraceId::new(format!("trace-module-registry-read-{suffix}")).unwrap(),
    })
    .await
    .expect("derive module read grant")
    .grant_id
}

fn module_invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
) -> crate::engine::Invocation {
    let context = CausalContext::new(
        ActorId::new(format!("agent:module-registry-{key}")).unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-module-registry-{key}")).unwrap(),
    )
    .with_scope("capability.execute")
    .with_scope(READ_SCOPE)
    .with_scope(RESOURCE_READ_SCOPE)
    .with_session_id(format!("session-module-registry-{key}"))
    .with_workspace_id(format!("workspace-module-registry-{key}"));

    crate::engine::Invocation {
        id: InvocationId::new(format!("invocation-module-registry-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

async fn inspect_with_resource(
    host: &EngineHostHandle,
    grant_id: AuthorityGrantId,
    key: &str,
) -> Result<Value, crate::shared::server::errors::CapabilityError> {
    inspect_with_resource_on(host, grant_id, key, &format!("module_manifest:{key}")).await
}

async fn inspect_with_resource_on(
    host: &EngineHostHandle,
    grant_id: AuthorityGrantId,
    key: &str,
    resource_id: &str,
) -> Result<Value, crate::shared::server::errors::CapabilityError> {
    let invocation = module_invocation(
        key,
        json!({
            "operation": "module_inspect",
            "moduleManifestResourceId": resource_id
        }),
        grant_id,
    );
    inspect_module_value(host, &invocation, &invocation.payload).await
}

async fn register_lax_type(host: &EngineHostHandle, kind: &str, schema_id: &str) {
    host.register_resource_type(RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema: json!({"type": "object"}),
        lifecycle_states: ["available"].into_iter().map(str::to_owned).collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: Vec::new(),
        default_retention: json!({"class": "module_registry_test"}),
        redaction_rules: json!({"projection": "test"}),
        materialization_rules: json!({"activation": "forbidden"}),
        required_capabilities: json!({"read": [RESOURCE_READ_SCOPE]}),
        owner_worker_id: WorkerId::new(WORKER).unwrap(),
    })
    .await
    .expect("register lax type");
}

async fn create_module_manifest_resource(
    host: &EngineHostHandle,
    resource_id: &str,
    scope: EngineResourceScope,
    payload: Value,
    lifecycle: &str,
) {
    create_resource(
        host,
        resource_id,
        MODULE_MANIFEST_KIND,
        Some(MODULE_MANIFEST_SCHEMA_ID),
        scope,
        payload,
        lifecycle,
    )
    .await;
}

async fn create_resource(
    host: &EngineHostHandle,
    resource_id: &str,
    kind: &str,
    schema_id: Option<&str>,
    scope: EngineResourceScope,
    payload: Value,
    lifecycle: &str,
) {
    host.create_resource(CreateResource {
        resource_id: Some(resource_id.to_owned()),
        kind: kind.to_owned(),
        schema_id: schema_id.map(str::to_owned),
        scope,
        owner_worker_id: WorkerId::new(WORKER).unwrap(),
        owner_actor_id: ActorId::new("system:module_registry_test").unwrap(),
        lifecycle: Some(lifecycle.to_owned()),
        policy: json!({
            "owner": "module_registry",
            "networkPolicy": "none",
            "activation": "forbidden"
        }),
        initial_payload: Some(payload),
        locations: Vec::new(),
        trace_id: TraceId::new(format!("trace-{}", resource_id.replace(':', "-"))).unwrap(),
        invocation_id: None,
    })
    .await
    .expect("create resource");
}

fn valid_manifest_payload(module_id: &str) -> Value {
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "identity": {
            "moduleId": module_id,
            "name": format!("Module Registry Test {module_id}"),
            "kind": "first_party_domain",
            "owner": "domains::module_registry",
            "summary": "Inspect only module registry test manifest",
            "version": "phase3-slice23a"
        },
        "capabilityDeclarations": [
            {
                "operation": "module_inspect",
                "effect": "read",
                "providerVisible": true,
                "description": "Inspect one safe module manifest projection"
            }
        ],
        "resourceDeclarations": [
            {
                "kind": MODULE_MANIFEST_KIND,
                "schemaId": MODULE_MANIFEST_SCHEMA_ID,
                "payloadSchemaVersion": SCHEMA_VERSION,
                "scope": "system"
            }
        ],
        "authorityNeeds": [
            {
                "scope": READ_SCOPE,
                "purpose": "read safe module manifest projections"
            },
            {
                "scope": RESOURCE_READ_SCOPE,
                "purpose": "read system module manifest resources"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "validated",
            "checks": [
                {
                    "id": "test_manifest_shape",
                    "status": "passed",
                    "summary": "Safe bounded manifest fixture"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-001"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::module_registry"
                }
            ]
        },
        "lifecycle": {
            "state": "validated",
            "activation": "inspect_only",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": {
            "localPaths": "absent",
            "environmentValues": "absent",
            "commands": "absent",
            "sensitiveValues": "absent",
            "grantIdentifiers": "absent",
            "authorityIdentifiers": "absent",
            "tokenLikeMaterial": "absent",
            "personalInfoLiterals": "absent"
        }
    })
}

fn assert_side_effects_are_absent(value: &Value) {
    assert_eq!(value["sideEffects"]["writes"], json!(false));
    assert_eq!(value["sideEffects"]["install"], json!(false));
    assert_eq!(value["sideEffects"]["activation"], json!(false));
    assert_eq!(value["sideEffects"]["execution"], json!(false));
    assert_eq!(value["sideEffects"]["dependencyResolution"], json!(false));
    assert_eq!(value["sideEffects"]["network"]["performed"], json!(false));
    assert_eq!(
        value["sideEffects"]["network"]["requiredPolicy"],
        json!("none")
    );
}

fn assert_provider_projection_has_no_raw_sensitive_material(value: &Value) {
    let rendered = serde_json::to_string(value).expect("serialize projection");
    for forbidden in [
        "/Users/",
        "/private/",
        "packages/agent/",
        "Bearer ",
        "sk-",
        "ghp_",
        "xox",
        "api_key",
        "apikey",
        "grant-",
        "grant_",
        "grant:",
        "authorityGrantId",
        "SECRET_ENV",
        "TRON_WORKER_TOKEN_JSON",
        "token-grant-secret",
        "--serve",
        "\"payload\"",
        "@example.",
    ] {
        assert!(
            !rendered.contains(forbidden),
            "provider projection leaked {forbidden}: {rendered}"
        );
    }
}

async fn list_all_module_manifest_count(host: &EngineHostHandle) -> usize {
    host.list_resources(ListResources {
        kind: Some(MODULE_MANIFEST_KIND.to_owned()),
        scope: Some(EngineResourceScope::System),
        lifecycle: None,
        limit: 1000,
    })
    .await
    .expect("list module manifests")
    .len()
}

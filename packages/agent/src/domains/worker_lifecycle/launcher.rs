use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::engine::{
    ActorContext, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, FunctionQuery,
    Invocation, ScopedWorkerToken, WorkerId, WorkerVisibility,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, policy_error};
use super::manifest::ValidatedPackage;
use super::resources::{
    conformance_resource_id, create_lifecycle_resource, link_if_possible,
    update_package_and_installation_status, update_status_resource,
};
use super::{CONFORMANCE_KIND, Deps};

#[derive(Clone, Debug)]
pub(super) struct WorkerLaunchRequest {
    pub(super) launch_attempt_id: String,
    pub(super) argv: Vec<String>,
    pub(super) working_directory: std::path::PathBuf,
    pub(super) env: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WorkerLaunchReceipt {
    pub(super) process_id: Option<u32>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WorkerStopReceipt {
    pub(super) stopped: bool,
}

#[async_trait]
pub(super) trait WorkerLauncher: Send + Sync {
    async fn launch(&self, request: WorkerLaunchRequest) -> Result<WorkerLaunchReceipt, String>;
    async fn stop(&self, launch_attempt_id: &str) -> Result<WorkerStopReceipt, String>;
}

#[derive(Default)]
pub(super) struct SystemWorkerLauncher {
    children: Mutex<BTreeMap<String, Child>>,
}

#[async_trait]
impl WorkerLauncher for SystemWorkerLauncher {
    async fn launch(&self, request: WorkerLaunchRequest) -> Result<WorkerLaunchReceipt, String> {
        let Some(program) = request.argv.first() else {
            return Err("launch argv must contain a program".to_owned());
        };
        let mut command = Command::new(program);
        command
            .args(request.argv.iter().skip(1))
            .current_dir(&request.working_directory)
            .env_clear()
            .envs(&request.env)
            .kill_on_drop(false);
        let child = command
            .spawn()
            .map_err(|error| format!("spawn worker process: {error}"))?;
        let process_id = child.id();
        self.children
            .lock()
            .await
            .insert(request.launch_attempt_id, child);
        Ok(WorkerLaunchReceipt { process_id })
    }

    async fn stop(&self, launch_attempt_id: &str) -> Result<WorkerStopReceipt, String> {
        let child = self.children.lock().await.remove(launch_attempt_id);
        let Some(mut child) = child else {
            return Ok(WorkerStopReceipt { stopped: false });
        };
        child
            .start_kill()
            .map_err(|error| format!("stop worker process: {error}"))?;
        let _ = child.wait().await;
        Ok(WorkerStopReceipt { stopped: true })
    }
}

pub(super) async fn derive_worker_grant(
    invocation: &Invocation,
    deps: &Deps,
    package: &ValidatedPackage,
) -> Result<crate::engine::EngineGrant, CapabilityError> {
    let parent_grant = deps
        .engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| {
            policy_error(format!(
                "unknown authority grant {}",
                invocation.causal_context.authority_grant_id
            ))
        })?;
    let grant_id = AuthorityGrantId::new(format!(
        "worker-lifecycle:{}:{}:{}",
        package.manifest.package_id, package.manifest.worker_id, invocation.id
    ))
    .map_err(engine_error)?;
    deps.engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(grant_id),
            parent_grant_id: invocation.causal_context.authority_grant_id.clone(),
            subject_actor_id: None,
            subject_worker_id: Some(
                WorkerId::new(package.manifest.worker_id.clone()).map_err(engine_error)?,
            ),
            subject_invocation_id: Some(invocation.id.clone()),
            allowed_capabilities: package.manifest.expected_functions.clone(),
            allowed_namespaces: package.manifest.namespace_claims.clone(),
            allowed_authority_scopes: package.manifest.requested_grants.authority_scopes.clone(),
            allowed_resource_kinds: package.manifest.requested_grants.resource_kinds.clone(),
            resource_selectors: package
                .manifest
                .namespace_claims
                .iter()
                .map(|namespace| format!("stream:{namespace}:*"))
                .collect(),
            file_roots: package.file_roots.clone(),
            network_policy: package.manifest.requested_grants.network_policy.clone(),
            max_risk: package.risk_level,
            budget: package.manifest.requested_grants.budget.clone(),
            expires_at: parent_grant.expires_at,
            can_delegate: false,
            provenance: json!({
                "source": "worker_lifecycle.launch_worker",
                "packageId": package.manifest.package_id,
                "packageVersion": package.manifest.package_version,
                "packageDigest": package.manifest.package_digest,
                "sourceRoot": package.source_root.display().to_string(),
            }),
            trace_id: invocation.causal_context.trace_id.clone(),
        })
        .await
        .map_err(engine_error)
}

pub(super) async fn worker_token_for_package(
    invocation: &Invocation,
    deps: &Deps,
    package: &ValidatedPackage,
    grant: &crate::engine::EngineGrant,
) -> Result<ScopedWorkerToken, CapabilityError> {
    Ok(ScopedWorkerToken {
        plugin_id: package.manifest.package_id.clone(),
        namespace_claims: package.manifest.namespace_claims.clone(),
        authority_grant_id: grant.grant_id.clone(),
        authority_grant_revision: grant.revision,
        authority_grant_hash: deps
            .engine_host
            .authority_grant_policy_hash(&grant.grant_id)
            .await
            .map_err(engine_error)?,
        resource_selectors: package
            .manifest
            .namespace_claims
            .iter()
            .map(|namespace| format!("stream:{namespace}:*"))
            .collect(),
        visibility_ceiling: WorkerVisibility::Workspace,
        trust_tier: "local_filesystem_package".to_owned(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
        expires_at: grant.expires_at.map(|value| value.to_rfc3339()),
        signature_status: "digest_provenance_checked".to_owned(),
    })
}

pub(super) fn launch_env(
    package: &ValidatedPackage,
    endpoint: &str,
    token_json: &str,
) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("TRON_WORKER_ENDPOINT".to_owned(), endpoint.to_owned()),
        ("TRON_WORKER_TOKEN_JSON".to_owned(), token_json.to_owned()),
        (
            "TRON_WORKER_PACKAGE_ID".to_owned(),
            package.manifest.package_id.clone(),
        ),
        (
            "TRON_WORKER_PACKAGE_VERSION".to_owned(),
            package.manifest.package_version.clone(),
        ),
        (
            "TRON_WORKER_PACKAGE_DIGEST".to_owned(),
            package.manifest.package_digest.clone(),
        ),
    ])
}

pub(super) fn launch_env_keys(package: &ValidatedPackage) -> Vec<String> {
    let mut keys = vec![
        "TRON_WORKER_ENDPOINT".to_owned(),
        "TRON_WORKER_TOKEN_JSON".to_owned(),
        "TRON_WORKER_PACKAGE_ID".to_owned(),
        "TRON_WORKER_PACKAGE_VERSION".to_owned(),
        "TRON_WORKER_PACKAGE_DIGEST".to_owned(),
    ];
    keys.extend(package.env_keys.clone());
    keys.sort();
    keys
}

pub(super) struct ConformanceReport {
    pub(super) passed: bool,
    pub(super) summary: String,
    pub(super) resource_id: String,
}

pub(super) async fn wait_for_conformance(
    deps: &Deps,
    invocation: &Invocation,
    package: &ValidatedPackage,
    launch_attempt_resource_id: &str,
) -> Result<ConformanceReport, CapabilityError> {
    let timeout = Duration::from_millis(package.manifest.conformance_policy.timeout_ms);
    let outcome = tokio::time::timeout(timeout, async {
        loop {
            let checks = conformance_checks(deps, invocation, package).await;
            let passed = checks.iter().all(|check| {
                check
                    .get("passed")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            });
            if passed {
                return (true, checks);
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await;
    let (passed, checks) = match outcome {
        Ok(result) => result,
        Err(_) => (false, conformance_checks(deps, invocation, package).await),
    };
    let status = if passed { "passed" } else { "failed" };
    let summary = if passed {
        "worker package conformance passed".to_owned()
    } else {
        "worker package conformance did not observe the expected live catalog".to_owned()
    };
    let payload = json!({
        "packageId": package.manifest.package_id,
        "packageVersion": package.manifest.package_version,
        "workerId": package.manifest.worker_id,
        "status": status,
        "checks": checks,
        "launchAttemptResourceId": launch_attempt_resource_id,
        "catalogRevision": deps.engine_host.catalog_revision().await.0,
    });
    let report_id = conformance_resource_id(&package.manifest, &invocation.id);
    let write = create_lifecycle_resource(
        deps,
        CONFORMANCE_KIND,
        report_id,
        status,
        payload,
        invocation,
    )
    .await?;
    link_if_possible(
        deps,
        &write.resource_id,
        launch_attempt_resource_id,
        "launch_attempt",
        invocation,
    )
    .await?;
    Ok(ConformanceReport {
        passed,
        summary,
        resource_id: write.resource_id,
    })
}

async fn conformance_checks(
    deps: &Deps,
    invocation: &Invocation,
    package: &ValidatedPackage,
) -> Vec<Value> {
    let mut checks = Vec::new();
    let worker_id = match WorkerId::new(package.manifest.worker_id.clone()) {
        Ok(worker_id) => worker_id,
        Err(error) => {
            return vec![json!({
                "name": "worker_id",
                "passed": false,
                "message": error.to_string(),
            })];
        }
    };
    match deps.engine_host.inspect_worker(&worker_id).await {
        Ok(worker) => {
            let claims = worker.namespace_claims.into_iter().collect::<BTreeSet<_>>();
            let expected = package
                .manifest
                .namespace_claims
                .iter()
                .cloned()
                .collect::<BTreeSet<_>>();
            checks.push(json!({
                "name": "worker_registered",
                "passed": true,
                "workerId": package.manifest.worker_id,
            }));
            checks.push(json!({
                "name": "namespace_claims",
                "passed": expected.is_subset(&claims),
                "expected": expected,
                "actual": claims,
            }));
        }
        Err(error) => checks.push(json!({
            "name": "worker_registered",
            "passed": false,
            "message": error.to_string(),
        })),
    }
    let actor = actor_context(&invocation.causal_context);
    for function in &package.manifest.expected_functions {
        let function_id = match FunctionId::new(function.clone()) {
            Ok(function_id) => function_id,
            Err(error) => {
                checks.push(json!({
                    "name": "function_id",
                    "functionId": function,
                    "passed": false,
                    "message": error.to_string(),
                }));
                continue;
            }
        };
        match deps
            .engine_host
            .inspect_function(&function_id, Some(&actor))
            .await
        {
            Ok(definition) => checks.push(json!({
                "name": "expected_function",
                "functionId": function,
                "passed": definition.owner_worker == worker_id,
                "ownerWorker": definition.owner_worker.as_str(),
            })),
            Err(error) => checks.push(json!({
                "name": "expected_function",
                "functionId": function,
                "passed": false,
                "message": error.to_string(),
            })),
        }
    }
    exact_function_check(deps, package, &worker_id, actor, &mut checks).await;
    trigger_checks(deps, package, &worker_id, &mut checks).await;
    checks
}

async fn exact_function_check(
    deps: &Deps,
    package: &ValidatedPackage,
    worker_id: &WorkerId,
    actor: ActorContext,
    checks: &mut Vec<Value>,
) {
    if !package.manifest.conformance_policy.require_exact_functions {
        return;
    }
    let discovered = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor),
            namespace_prefix: package.manifest.namespace_claims.first().cloned(),
            include_internal: true,
            ..FunctionQuery::default()
        })
        .await
        .into_iter()
        .filter(|definition| definition.owner_worker == *worker_id)
        .map(|definition| definition.id.as_str().to_owned())
        .collect::<BTreeSet<_>>();
    let expected = package
        .manifest
        .expected_functions
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>();
    checks.push(json!({
        "name": "exact_functions",
        "passed": discovered == expected,
        "expected": expected,
        "actual": discovered,
    }));
}

async fn trigger_checks(
    deps: &Deps,
    package: &ValidatedPackage,
    worker_id: &WorkerId,
    checks: &mut Vec<Value>,
) {
    for trigger in &package.manifest.expected_triggers {
        match crate::engine::TriggerId::new(trigger.clone()) {
            Ok(trigger_id) => match deps.engine_host.inspect_trigger(&trigger_id).await {
                Ok(definition) => checks.push(json!({
                    "name": "expected_trigger",
                    "triggerId": trigger,
                    "passed": definition.owner_worker == *worker_id,
                    "ownerWorker": definition.owner_worker.as_str(),
                })),
                Err(error) => checks.push(json!({
                    "name": "expected_trigger",
                    "triggerId": trigger,
                    "passed": false,
                    "message": error.to_string(),
                })),
            },
            Err(error) => checks.push(json!({
                "name": "expected_trigger",
                "triggerId": trigger,
                "passed": false,
                "message": error.to_string(),
            })),
        }
    }
}

fn actor_context(context: &CausalContext) -> ActorContext {
    let mut actor = ActorContext::new(
        context.actor_id.clone(),
        context.actor_kind.clone(),
        context.authority_grant_id.clone(),
    );
    for scope in &context.authority_scopes {
        actor = actor.with_scope(scope.clone());
    }
    if let Some(session_id) = &context.session_id {
        actor = actor.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &context.workspace_id {
        actor = actor.with_workspace_id(workspace_id.clone());
    }
    actor
}

pub(super) async fn mark_launch_failed(
    deps: &Deps,
    invocation: &Invocation,
    package: &ValidatedPackage,
    launch_attempt_resource_id: &str,
    endpoint: &str,
    process_id: Option<u32>,
    error: &str,
) -> Result<(), CapabilityError> {
    let mut payload = json!({
        "packageId": package.manifest.package_id,
        "packageVersion": package.manifest.package_version,
        "workerId": package.manifest.worker_id,
        "status": "failed",
        "argv": package.argv,
        "workingDirectory": package.working_directory.display().to_string(),
        "envKeys": launch_env_keys(package),
        "endpoint": endpoint,
        "failure": {"message": error},
    });
    if let Some(process_id) = process_id
        && let Some(object) = payload.as_object_mut()
    {
        object.insert("processId".to_owned(), json!(process_id));
    }
    update_status_resource(
        deps,
        launch_attempt_resource_id,
        "failed",
        payload,
        invocation,
    )
    .await?;
    let _ = update_package_and_installation_status(
        deps,
        invocation,
        package,
        "failed",
        Some(error.to_owned()),
    )
    .await?;
    Ok(())
}

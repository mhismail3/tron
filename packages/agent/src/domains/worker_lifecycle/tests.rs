use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Mutex;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, DeriveGrant, EffectClass,
    FunctionDefinition, FunctionId, Invocation, InvocationId, RUNTIME_METADATA_WORKING_DIRECTORY,
    RiskLevel, TraceId, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
};

use super::handlers::{
    install_package, launch_worker, propose_package_change, set_package_enabled, stop_worker,
};
use super::launcher::{
    WorkerLaunchReceipt, WorkerLaunchRequest, WorkerLauncher, WorkerStopReceipt,
};
use super::manifest::{
    ConformancePolicy, PackageSource, RequestedGrantPolicy, RollbackPolicy, WorkerPackageManifest,
    validate_manifest_full, validate_manifest_shape,
};
use super::resources::launch_attempt_resource_id;
use super::{
    APPLY_SCOPE, Deps, ENABLE_FUNCTION, INSTALL_FUNCTION, LAUNCH_FUNCTION, PACKAGE_SCHEMA_VERSION,
    PROPOSE_FUNCTION, PROPOSE_SCOPE, SOURCE_KIND_LOCAL_FILESYSTEM, STOP_FUNCTION,
};

#[derive(Default)]
struct FakeLauncher {
    launches: Mutex<Vec<WorkerLaunchRequest>>,
    fail_launch: bool,
}

#[async_trait]
impl WorkerLauncher for FakeLauncher {
    async fn launch(&self, request: WorkerLaunchRequest) -> Result<WorkerLaunchReceipt, String> {
        if self.fail_launch {
            return Err("fake launch failure".to_owned());
        }
        self.launches.lock().await.push(request);
        Ok(WorkerLaunchReceipt {
            process_id: Some(42),
        })
    }

    async fn stop(&self, _launch_attempt_id: &str) -> Result<WorkerStopReceipt, String> {
        Ok(WorkerStopReceipt { stopped: true })
    }
}

fn manifest(root: &Path) -> WorkerPackageManifest {
    WorkerPackageManifest {
        schema_version: PACKAGE_SCHEMA_VERSION.to_owned(),
        package_id: "local.echo".to_owned(),
        package_version: "1.0.0".to_owned(),
        package_digest: format!("sha256:{}", "a".repeat(64)),
        provenance: json!({"source": "test"}),
        source: PackageSource {
            kind: SOURCE_KIND_LOCAL_FILESYSTEM.to_owned(),
            path: root.display().to_string(),
        },
        worker_id: "local_echo".to_owned(),
        namespace_claims: vec!["local_echo".to_owned()],
        launch_command: vec!["worker.sh".to_owned(), "--serve".to_owned()],
        working_directory: ".".to_owned(),
        env_allowlist: vec!["PATH".to_owned()],
        expected_functions: vec!["local_echo::run".to_owned()],
        expected_triggers: Vec::new(),
        requested_grants: RequestedGrantPolicy {
            authority_scopes: vec!["local_echo.run".to_owned()],
            resource_kinds: vec!["artifact".to_owned()],
            file_roots: Vec::new(),
            network_policy: "loopback".to_owned(),
            max_risk: "medium".to_owned(),
            budget: json!({"remainingInvocations": 1}),
        },
        conformance_policy: ConformancePolicy {
            timeout_ms: 50,
            require_exact_functions: false,
        },
        rollback_policy: RollbackPolicy {
            on_failure: "stop_worker".to_owned(),
        },
    }
}

fn package_dir() -> (TempDir, PathBuf) {
    let temp = tempfile::tempdir().expect("tempdir");
    let package = temp.path().join("local.echo");
    std::fs::create_dir_all(&package).expect("package dir");
    std::fs::write(package.join("worker.sh"), "#!/bin/sh\n").expect("worker file");
    (temp, package)
}

async fn derived_lifecycle_grant(handle: &crate::engine::EngineHostHandle) -> AuthorityGrantId {
    let grant = handle
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new("worker-lifecycle-test").unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
            subject_actor_id: None,
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["*".to_owned()],
            allowed_namespaces: vec!["*".to_owned()],
            allowed_authority_scopes: vec![
                APPLY_SCOPE.to_owned(),
                PROPOSE_SCOPE.to_owned(),
                "resource.write".to_owned(),
                "resource.read".to_owned(),
                "local_echo.run".to_owned(),
            ],
            allowed_resource_kinds: vec!["*".to_owned()],
            resource_selectors: vec!["*".to_owned()],
            file_roots: vec!["*".to_owned()],
            network_policy: "unrestricted".to_owned(),
            max_risk: RiskLevel::Critical,
            budget: json!({"class": "test"}),
            expires_at: None,
            can_delegate: true,
            provenance: json!({"source": "worker_lifecycle_test"}),
            trace_id: TraceId::new("worker-lifecycle-test-trace").unwrap(),
        })
        .await
        .expect("derive lifecycle grant");
    grant.grant_id
}

fn invocation(
    function_id: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    actor_kind: ActorKind,
    scopes: &[&str],
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new("test-user").unwrap(),
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-{function_id}")).unwrap(),
    )
    .with_workspace_id("workspace-test")
    .with_idempotency_key(format!("idem-{function_id}"))
    .with_runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY, "/tmp");
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-{function_id}")).unwrap(),
        function_id: FunctionId::new(function_id).unwrap(),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

async fn test_deps() -> (TempDir, Deps, PathBuf) {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path().join("workers");
    let package = root.join("local.echo");
    std::fs::create_dir_all(&package).expect("package dir");
    std::fs::write(package.join("worker.sh"), "#!/bin/sh\n").expect("worker file");
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let deps = Deps::for_test(handle, root, Arc::new(FakeLauncher::default()));
    (temp, deps, package)
}

async fn register_expected_worker(handle: &crate::engine::EngineHostHandle) {
    let worker_id = WorkerId::new("local_echo").unwrap();
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        ActorId::new("worker-owner").unwrap(),
        AuthorityGrantId::new("worker-runtime").unwrap(),
    )
    .with_namespace_claim("local_echo");
    handle.register_worker(worker, false).await.unwrap();
    let mut function = FunctionDefinition::new(
        FunctionId::new("local_echo::run").unwrap(),
        worker_id,
        "test external worker function",
        VisibilityScope::System,
        EffectClass::DeterministicCompute,
    );
    function.required_authority = crate::engine::AuthorityRequirement::scope("local_echo.run");
    handle
        .register_function(function, None, false)
        .await
        .unwrap();
}

#[test]
fn manifest_shape_rejects_wildcard_namespace() {
    let (_temp, package) = package_dir();
    let mut manifest = manifest(&package);
    manifest.namespace_claims = vec!["*".to_owned()];
    assert!(validate_manifest_shape(&manifest).is_err());
}

#[test]
fn manifest_shape_rejects_shell_launch_fragments() {
    let (_temp, package) = package_dir();
    let mut manifest = manifest(&package);
    manifest.launch_command = vec!["worker.sh && rm -rf /".to_owned()];
    assert!(validate_manifest_shape(&manifest).is_err());
}

#[test]
fn manifest_full_rejects_source_path_escape() {
    let temp = tempfile::tempdir().expect("tempdir");
    let outside = tempfile::tempdir().expect("outside");
    let mut manifest = manifest(outside.path());
    manifest.source.path = outside.path().display().to_string();
    let deps = Deps::for_test(
        crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
        temp.path().join("workers"),
        Arc::new(FakeLauncher::default()),
    );
    assert!(validate_manifest_full(manifest, &deps).is_err());
}

#[test]
fn manifest_full_accepts_local_package_under_root() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path().join("workers");
    let package = root.join("local.echo");
    std::fs::create_dir_all(&package).expect("package dir");
    std::fs::write(package.join("worker.sh"), "#!/bin/sh\n").expect("worker file");
    let deps = Deps::for_test(
        crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
        root,
        Arc::new(FakeLauncher::default()),
    );
    let validated = validate_manifest_full(manifest(&package), &deps).expect("valid package");
    assert_eq!(validated.argv.len(), 2);
    assert!(validated.argv[0].ends_with("worker.sh"));
}

#[tokio::test]
async fn proposal_creates_inert_resource_without_installation() {
    let (_temp, deps, package) = test_deps().await;
    let grant = derived_lifecycle_grant(&deps.engine_host).await;
    let invocation = invocation(
        PROPOSE_FUNCTION,
        json!({"manifest": manifest(&package), "summary": "propose local worker"}),
        grant,
        ActorKind::Agent,
        &[PROPOSE_SCOPE],
    );
    let result = propose_package_change(&invocation, &deps)
        .await
        .expect("proposal");
    assert_eq!(result["status"], "proposed");
    let proposal_id = result["proposalResourceId"].as_str().unwrap();
    assert!(
        deps.engine_host
            .inspect_resource(proposal_id)
            .await
            .unwrap()
            .is_some()
    );
    assert!(
        deps.engine_host
            .inspect_resource("worker_package:local.echo:1.0.0")
            .await
            .unwrap()
            .is_none(),
        "proposal must not install or activate a package"
    );
}

#[tokio::test]
async fn install_and_enable_write_package_and_installation_resources() {
    let (_temp, deps, package) = test_deps().await;
    let grant = derived_lifecycle_grant(&deps.engine_host).await;
    let install_invocation = invocation(
        INSTALL_FUNCTION,
        json!({"manifest": manifest(&package)}),
        grant.clone(),
        ActorKind::User,
        &[APPLY_SCOPE],
    );
    let install = install_package(&install_invocation, &deps)
        .await
        .expect("install package");
    assert_eq!(install["status"], "installed");

    let enable_invocation = invocation(
        ENABLE_FUNCTION,
        json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
        grant,
        ActorKind::User,
        &[APPLY_SCOPE],
    );
    let enabled = set_package_enabled(&enable_invocation, &deps, true)
        .await
        .expect("enable package");
    assert_eq!(enabled["status"], "enabled");
    let installation = deps
        .engine_host
        .inspect_resource("worker_package_installation:local.echo:1.0.0")
        .await
        .unwrap()
        .expect("installation resource");
    assert_eq!(installation.resource.lifecycle, "enabled");
}

#[tokio::test]
async fn apply_rejects_agent_actor_and_bootstrap_grant() {
    let (_temp, deps, package) = test_deps().await;
    let bootstrap = AuthorityGrantId::new("engine-system").unwrap();
    let manifest = manifest(&package);
    let bootstrap_invocation = invocation(
        INSTALL_FUNCTION,
        json!({"manifest": manifest.clone()}),
        bootstrap,
        ActorKind::User,
        &[APPLY_SCOPE],
    );
    assert!(install_package(&bootstrap_invocation, &deps).await.is_err());

    let grant = derived_lifecycle_grant(&deps.engine_host).await;
    let agent_invocation = invocation(
        INSTALL_FUNCTION,
        json!({"manifest": manifest}),
        grant,
        ActorKind::Agent,
        &[APPLY_SCOPE],
    );
    assert!(install_package(&agent_invocation, &deps).await.is_err());
}

#[tokio::test]
async fn launch_failure_records_failed_state() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path().join("workers");
    let package = root.join("local.echo");
    std::fs::create_dir_all(&package).expect("package dir");
    std::fs::write(package.join("worker.sh"), "#!/bin/sh\n").expect("worker file");
    let deps = Deps::for_test(
        crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
        root,
        Arc::new(FakeLauncher {
            launches: Mutex::new(Vec::new()),
            fail_launch: true,
        }),
    );
    let grant = derived_lifecycle_grant(&deps.engine_host).await;
    let manifest = manifest(&package);
    install_package(
        &invocation(
            INSTALL_FUNCTION,
            json!({"manifest": manifest.clone()}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
    )
    .await
    .unwrap();
    set_package_enabled(
        &invocation(
            ENABLE_FUNCTION,
            json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
        true,
    )
    .await
    .unwrap();
    let launch_invocation = invocation(
        LAUNCH_FUNCTION,
        json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
        grant,
        ActorKind::User,
        &[APPLY_SCOPE],
    );
    assert!(launch_worker(&launch_invocation, &deps).await.is_err());
    let launch = deps
        .engine_host
        .inspect_resource(&launch_attempt_resource_id(
            &manifest,
            &launch_invocation.id,
        ))
        .await
        .unwrap()
        .expect("launch attempt resource");
    assert_eq!(launch.resource.lifecycle, "failed");
    assert!(launch.versions.last().unwrap().payload["argv"].is_array());
}

#[tokio::test]
async fn conformance_failure_records_failed_launch_attempt() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path().join("workers");
    let package = root.join("local.echo");
    std::fs::create_dir_all(&package).expect("package dir");
    std::fs::write(package.join("worker.sh"), "#!/bin/sh\n").expect("worker file");
    let deps = Deps::for_test(
        crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
        root,
        Arc::new(FakeLauncher::default()),
    );
    let grant = derived_lifecycle_grant(&deps.engine_host).await;
    let manifest = manifest(&package);
    install_package(
        &invocation(
            INSTALL_FUNCTION,
            json!({"manifest": manifest.clone()}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
    )
    .await
    .unwrap();
    set_package_enabled(
        &invocation(
            ENABLE_FUNCTION,
            json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
        true,
    )
    .await
    .unwrap();
    let launch_invocation = invocation(
        LAUNCH_FUNCTION,
        json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
        grant,
        ActorKind::User,
        &[APPLY_SCOPE],
    );
    let error = launch_worker(&launch_invocation, &deps)
        .await
        .expect_err("conformance should fail without worker registration");
    assert!(format!("{error}").contains("worker conformance failed"));
    let launch = deps
        .engine_host
        .inspect_resource(&launch_attempt_resource_id(
            &manifest,
            &launch_invocation.id,
        ))
        .await
        .unwrap()
        .expect("launch attempt resource");
    assert_eq!(launch.resource.lifecycle, "failed");
    assert_eq!(launch.versions.last().unwrap().payload["processId"], 42);
}

#[tokio::test]
async fn launch_success_mints_scoped_token_and_records_running_state() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path().join("workers");
    let package = root.join("local.echo");
    std::fs::create_dir_all(&package).expect("package dir");
    std::fs::write(package.join("worker.sh"), "#!/bin/sh\n").expect("worker file");
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    register_expected_worker(&handle).await;
    let fake = Arc::new(FakeLauncher::default());
    let deps = Deps::for_test(handle, root, fake.clone());
    let grant = derived_lifecycle_grant(&deps.engine_host).await;
    install_package(
        &invocation(
            INSTALL_FUNCTION,
            json!({"manifest": manifest(&package)}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
    )
    .await
    .unwrap();
    set_package_enabled(
        &invocation(
            ENABLE_FUNCTION,
            json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
        true,
    )
    .await
    .unwrap();
    let launched = launch_worker(
        &invocation(
            LAUNCH_FUNCTION,
            json!({"packageId": "local.echo", "packageVersion": "1.0.0"}),
            grant.clone(),
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
    )
    .await
    .expect("launch worker");
    assert_eq!(launched["status"], "running");
    assert_eq!(launched["workerToken"]["pluginId"], "local.echo");
    let launches = fake.launches.lock().await;
    assert!(
        launches
            .first()
            .expect("fake launch recorded")
            .env
            .contains_key("TRON_WORKER_TOKEN_JSON")
    );
    drop(launches);
    let launch_attempt_id = launched["launchAttemptResourceId"].as_str().unwrap();
    let stopped = stop_worker(
        &invocation(
            STOP_FUNCTION,
            json!({"launchAttemptResourceId": launch_attempt_id, "reason": "test stop"}),
            grant,
            ActorKind::User,
            &[APPLY_SCOPE],
        ),
        &deps,
    )
    .await
    .expect("stop worker");
    assert_eq!(stopped["status"], "stopped");
    let launch = deps
        .engine_host
        .inspect_resource(launch_attempt_id)
        .await
        .unwrap()
        .expect("launch attempt resource");
    assert_eq!(launch.resource.lifecycle, "stopped");
    let payload = &launch.versions.last().unwrap().payload;
    assert_eq!(payload["packageId"], "local.echo");
    assert!(payload["argv"].is_array());
    assert_eq!(payload["reason"], "test stop");
}

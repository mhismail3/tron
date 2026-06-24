use std::sync::atomic::Ordering;

use serde_json::{Value, json};

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;

use super::authority::{ensure_apply_authority, ensure_proposal_authority};
use super::errors::{internal_error, policy_error};
use super::launcher::{
    WorkerLaunchRequest, derive_worker_grant, launch_env, launch_env_keys, mark_launch_failed,
    wait_for_conformance, worker_token_for_package,
};
use super::manifest::{
    ValidatedPackage, manifest_from_payload, validate_manifest_full, validate_manifest_shape,
};
use super::params::{package_ref_from_payload, reason_from_payload, required_string};
use super::resources::{
    create_lifecycle_resource, current_resource_payload, ensure_installation_lifecycle,
    installation_payload, installation_resource_id, json_patch_status, launch_attempt_resource_id,
    link_if_possible, load_installed_package, package_payload, package_resource_id,
    proposal_resource_id, publish_lifecycle_event, update_package_and_installation_status,
    update_status_resource, upsert_lifecycle_resource,
};
use super::{Deps, INSTALLATION_KIND, LAUNCH_KIND, PACKAGE_KIND, PROPOSAL_KIND};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "propose_package_change" => |invocation, deps| {
            propose_package_change(invocation, deps).await
        },
        "install_package" => |invocation, deps| {
            install_package(invocation, deps).await
        },
        "enable_package" => |invocation, deps| {
            set_package_enabled(invocation, deps, true).await
        },
        "disable_package" => |invocation, deps| {
            set_package_enabled(invocation, deps, false).await
        },
        "launch_worker" => |invocation, deps| {
            launch_worker(invocation, deps).await
        },
        "stop_worker" => |invocation, deps| {
            stop_worker(invocation, deps).await
        },
        "retire_package" => |invocation, deps| {
            retire_package(invocation, deps).await
        },
    ];
}

pub(super) async fn propose_package_change(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    ensure_proposal_authority(invocation, deps).await?;
    let manifest = manifest_from_payload(&invocation.payload)?;
    validate_manifest_shape(&manifest)?;
    let summary = required_string(&invocation.payload, "summary")?;
    let resource_id = proposal_resource_id(&manifest, &invocation.id);
    let payload = json!({
        "packageId": manifest.package_id,
        "packageVersion": manifest.package_version,
        "summary": summary,
        "status": "proposed",
        "manifest": manifest,
        "proposedBy": invocation.causal_context.actor_id.as_str(),
        "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
    });
    let write = create_lifecycle_resource(
        deps,
        PROPOSAL_KIND,
        resource_id,
        "proposed",
        payload,
        invocation,
    )
    .await?;
    let cursor = publish_lifecycle_event(
        deps,
        invocation,
        "worker_package.proposed",
        json!({
            "proposalResourceId": write.resource_id,
            "packageId": manifest.package_id,
            "packageVersion": manifest.package_version,
            "inert": true,
        }),
    )
    .await?;
    Ok(json!({
        "status": "proposed",
        "proposalResourceId": write.resource_id,
        "streamCursor": cursor.0,
    }))
}

pub(super) async fn install_package(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    ensure_apply_authority(invocation, deps).await?;
    let package = validate_manifest_full(manifest_from_payload(&invocation.payload)?, deps)?;
    let package_write = upsert_lifecycle_resource(
        deps,
        PACKAGE_KIND,
        package_resource_id(&package.manifest),
        "installed",
        package_payload(&package, "installed"),
        invocation,
    )
    .await?;
    let installation_write = upsert_lifecycle_resource(
        deps,
        INSTALLATION_KIND,
        installation_resource_id(&package.manifest),
        "installed",
        installation_payload(
            &package,
            &package_write.resource_id,
            "installed",
            invocation,
            None,
        ),
        invocation,
    )
    .await?;
    link_if_possible(
        deps,
        &installation_write.resource_id,
        &package_write.resource_id,
        "package",
        invocation,
    )
    .await?;
    let cursor = publish_lifecycle_event(
        deps,
        invocation,
        "worker_package.installed",
        json!({
            "packageResourceId": package_write.resource_id,
            "installationResourceId": installation_write.resource_id,
            "packageId": package.manifest.package_id,
            "packageVersion": package.manifest.package_version,
            "packageDigest": package.manifest.package_digest,
        }),
    )
    .await?;
    Ok(json!({
        "status": "installed",
        "packageResourceId": package_write.resource_id,
        "installationResourceId": installation_write.resource_id,
        "streamCursor": cursor.0,
    }))
}

pub(super) async fn set_package_enabled(
    invocation: &Invocation,
    deps: &Deps,
    enabled: bool,
) -> Result<Value, CapabilityError> {
    ensure_apply_authority(invocation, deps).await?;
    let package_ref = package_ref_from_payload(&invocation.payload)?;
    let package = load_installed_package(deps, &package_ref).await?;
    let status = if enabled { "enabled" } else { "disabled" };
    let package_write = update_status_resource(
        deps,
        &package_resource_id(&package.manifest),
        status,
        json_patch_status(&package_payload(&package, status), invocation, status),
        invocation,
    )
    .await?;
    let installation_write = update_status_resource(
        deps,
        &installation_resource_id(&package.manifest),
        status,
        json_patch_status(
            &installation_payload(
                &package,
                &package_write.resource_id,
                status,
                invocation,
                reason_from_payload(&invocation.payload),
            ),
            invocation,
            status,
        ),
        invocation,
    )
    .await?;
    let cursor = publish_lifecycle_event(
        deps,
        invocation,
        if enabled {
            "worker_package.enabled"
        } else {
            "worker_package.disabled"
        },
        json!({
            "packageResourceId": package_write.resource_id,
            "installationResourceId": installation_write.resource_id,
            "packageId": package.manifest.package_id,
            "packageVersion": package.manifest.package_version,
            "reason": reason_from_payload(&invocation.payload),
        }),
    )
    .await?;
    Ok(json!({
        "status": status,
        "packageResourceId": package_write.resource_id,
        "installationResourceId": installation_write.resource_id,
        "streamCursor": cursor.0,
    }))
}

pub(super) async fn launch_worker(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    ensure_apply_authority(invocation, deps).await?;
    let package_ref = package_ref_from_payload(&invocation.payload)?;
    let package = load_installed_package(deps, &package_ref).await?;
    ensure_installation_lifecycle(deps, &package.manifest, "enabled").await?;
    let grant = derive_worker_grant(invocation, deps, &package).await?;
    let token = worker_token_for_package(invocation, deps, &package, &grant).await?;
    let token_json = serde_json::to_string(&token).map_err(internal_error)?;
    let endpoint = format!(
        "ws://127.0.0.1:{}/engine/workers",
        deps.ws_port.load(Ordering::SeqCst)
    );
    let launch_attempt_id = launch_attempt_resource_id(&package.manifest, &invocation.id);
    let launch_write = create_launch_attempt(
        deps,
        invocation,
        &package,
        &launch_attempt_id,
        &endpoint,
        grant.grant_id.as_str(),
    )
    .await?;
    let mut env = launch_env(&package, &endpoint, &token_json);
    for key in &package.env_keys {
        if let Ok(value) = std::env::var(key) {
            env.insert(key.clone(), value);
        }
    }
    let receipt = match deps
        .launcher
        .launch(WorkerLaunchRequest {
            launch_attempt_id: launch_attempt_id.clone(),
            argv: package.argv.clone(),
            working_directory: package.working_directory.clone(),
            env,
        })
        .await
    {
        Ok(receipt) => receipt,
        Err(error) => {
            let _ = mark_launch_failed(
                deps,
                invocation,
                &package,
                &launch_write.resource_id,
                &endpoint,
                None,
                &error,
            )
            .await;
            return Err(policy_error(format!("worker launch failed: {error}")));
        }
    };
    update_launch_attempt(
        deps,
        invocation,
        &package,
        &launch_write.resource_id,
        "launching",
        &endpoint,
        grant.grant_id.as_str(),
        receipt.process_id,
    )
    .await?;
    let report =
        wait_for_conformance(deps, invocation, &package, &launch_write.resource_id).await?;
    let final_status = if report.passed { "running" } else { "failed" };
    update_package_and_installation_status(deps, invocation, &package, final_status, None).await?;
    if !report.passed {
        let _ = deps.launcher.stop(&launch_attempt_id).await;
        let failure = format!("worker conformance failed: {}", report.summary);
        let _ = mark_launch_failed(
            deps,
            invocation,
            &package,
            &launch_write.resource_id,
            &endpoint,
            receipt.process_id,
            &failure,
        )
        .await;
        return Err(policy_error(failure));
    }
    update_launch_attempt(
        deps,
        invocation,
        &package,
        &launch_write.resource_id,
        "running",
        &endpoint,
        grant.grant_id.as_str(),
        receipt.process_id,
    )
    .await?;
    let cursor = publish_lifecycle_event(
        deps,
        invocation,
        "worker_package.launched",
        json!({
            "packageId": package.manifest.package_id,
            "packageVersion": package.manifest.package_version,
            "workerId": package.manifest.worker_id,
            "launchAttemptResourceId": launch_write.resource_id,
            "conformanceReportResourceId": report.resource_id,
            "tokenGrantId": grant.grant_id.as_str(),
        }),
    )
    .await?;
    Ok(json!({
        "status": "running",
        "packageResourceId": package_resource_id(&package.manifest),
        "installationResourceId": installation_resource_id(&package.manifest),
        "launchAttemptResourceId": launch_write.resource_id,
        "conformanceReportResourceId": report.resource_id,
        "workerToken": token,
        "streamCursor": cursor.0,
    }))
}

pub(super) async fn stop_worker(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    ensure_apply_authority(invocation, deps).await?;
    let launch_attempt_id = required_string(&invocation.payload, "launchAttemptResourceId")?;
    let receipt = deps
        .launcher
        .stop(&launch_attempt_id)
        .await
        .map_err(|error| policy_error(format!("worker stop failed: {error}")))?;
    let mut payload = current_resource_payload(deps, &launch_attempt_id).await?;
    let object = payload
        .as_object_mut()
        .ok_or_else(|| internal_error("worker launch attempt payload must be an object"))?;
    object.insert("status".to_owned(), json!("stopped"));
    object.insert("stopped".to_owned(), json!(receipt.stopped));
    if let Some(reason) = reason_from_payload(&invocation.payload) {
        object.insert("reason".to_owned(), json!(reason));
    }
    let write =
        update_status_resource(deps, &launch_attempt_id, "stopped", payload, invocation).await?;
    let cursor = publish_lifecycle_event(
        deps,
        invocation,
        "worker_package.stopped",
        json!({
            "launchAttemptResourceId": write.resource_id,
            "stopped": receipt.stopped,
            "reason": reason_from_payload(&invocation.payload),
        }),
    )
    .await?;
    Ok(json!({
        "status": "stopped",
        "launchAttemptResourceId": write.resource_id,
        "streamCursor": cursor.0,
    }))
}

pub(super) async fn retire_package(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    ensure_apply_authority(invocation, deps).await?;
    let package_ref = package_ref_from_payload(&invocation.payload)?;
    let package = load_installed_package(deps, &package_ref).await?;
    let (package_write, installation_write) = update_package_and_installation_status(
        deps,
        invocation,
        &package,
        "retired",
        reason_from_payload(&invocation.payload),
    )
    .await?;
    let cursor = publish_lifecycle_event(
        deps,
        invocation,
        "worker_package.retired",
        json!({
            "packageResourceId": package_write.resource_id,
            "installationResourceId": installation_write.resource_id,
            "packageId": package.manifest.package_id,
            "packageVersion": package.manifest.package_version,
            "reason": reason_from_payload(&invocation.payload),
        }),
    )
    .await?;
    Ok(json!({
        "status": "retired",
        "packageResourceId": package_write.resource_id,
        "installationResourceId": installation_write.resource_id,
        "streamCursor": cursor.0,
    }))
}

async fn create_launch_attempt(
    deps: &Deps,
    invocation: &Invocation,
    package: &ValidatedPackage,
    launch_attempt_id: &str,
    endpoint: &str,
    token_grant_id: &str,
) -> Result<super::resources::ResourceWrite, CapabilityError> {
    create_lifecycle_resource(
        deps,
        LAUNCH_KIND,
        launch_attempt_id.to_owned(),
        "launching",
        launch_attempt_payload(package, "launching", endpoint, token_grant_id, None),
        invocation,
    )
    .await
}

async fn update_launch_attempt(
    deps: &Deps,
    invocation: &Invocation,
    package: &ValidatedPackage,
    launch_attempt_resource_id: &str,
    status: &str,
    endpoint: &str,
    token_grant_id: &str,
    process_id: Option<u32>,
) -> Result<(), CapabilityError> {
    update_status_resource(
        deps,
        launch_attempt_resource_id,
        status,
        launch_attempt_payload(package, status, endpoint, token_grant_id, process_id),
        invocation,
    )
    .await?;
    Ok(())
}

fn launch_attempt_payload(
    package: &ValidatedPackage,
    status: &str,
    endpoint: &str,
    token_grant_id: &str,
    process_id: Option<u32>,
) -> Value {
    let mut payload = json!({
        "packageId": package.manifest.package_id,
        "packageVersion": package.manifest.package_version,
        "workerId": package.manifest.worker_id,
        "status": status,
        "argv": package.argv,
        "workingDirectory": package.working_directory.display().to_string(),
        "envKeys": launch_env_keys(package),
        "endpoint": endpoint,
        "tokenGrantId": token_grant_id,
    });
    if let Some(process_id) = process_id
        && let Some(object) = payload.as_object_mut()
    {
        object.insert("processId".to_owned(), json!(process_id));
    }
    payload
}

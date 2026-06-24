use serde_json::{Value, json};

use crate::engine::{
    CreateResource, EngineResourceScope, Invocation, InvocationId, LinkResources,
    PublishStreamEvent, StreamCursor, UpdateResource, VisibilityScope, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, internal_error};
use super::manifest::{ValidatedPackage, WorkerPackageManifest, manifest_from_payload};
use super::params::PackageRef;
use super::{Deps, manifest::validate_manifest_full};
use super::{WORKER, WORKER_LIFECYCLE_TOPIC};

#[derive(Clone, Debug)]
pub(super) struct ResourceWrite {
    pub(super) resource_id: String,
}

pub(super) async fn load_installed_package(
    deps: &Deps,
    package_ref: &PackageRef,
) -> Result<ValidatedPackage, CapabilityError> {
    let resource_id = format!(
        "worker_package:{}:{}",
        package_ref.package_id, package_ref.package_version
    );
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "WORKER_PACKAGE_NOT_FOUND".to_owned(),
            message: format!(
                "worker package {} {} is not installed",
                package_ref.package_id, package_ref.package_version
            ),
        })?;
    let version = inspection
        .versions
        .iter()
        .find(|version| {
            Some(&version.version_id) == inspection.resource.current_version_id.as_ref()
        })
        .or_else(|| inspection.versions.last())
        .ok_or_else(|| internal_error("worker package resource has no versions"))?;
    let manifest = manifest_from_payload(&json!({"manifest": version.payload["manifest"]}))?;
    validate_manifest_full(manifest, deps)
}

pub(super) async fn ensure_installation_lifecycle(
    deps: &Deps,
    manifest: &WorkerPackageManifest,
    required: &str,
) -> Result<(), CapabilityError> {
    let resource_id = installation_resource_id(manifest);
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "WORKER_PACKAGE_INSTALLATION_NOT_FOUND".to_owned(),
            message: format!("missing worker package installation resource {resource_id}"),
        })?;
    if inspection.resource.lifecycle != required {
        return Err(super::errors::policy_error(format!(
            "worker package installation {} must be {required}; current lifecycle is {}",
            inspection.resource.resource_id, inspection.resource.lifecycle
        )));
    }
    Ok(())
}

pub(super) async fn create_lifecycle_resource(
    deps: &Deps,
    kind: &str,
    resource_id: String,
    lifecycle: &str,
    payload: Value,
    invocation: &Invocation,
) -> Result<ResourceWrite, CapabilityError> {
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: kind.to_owned(),
            schema_id: None,
            scope: scope_for_invocation(invocation),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: json!({"owner": WORKER, "authority": super::APPLY_SCOPE}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(ResourceWrite {
        resource_id: resource.resource_id,
    })
}

pub(super) async fn upsert_lifecycle_resource(
    deps: &Deps,
    kind: &str,
    resource_id: String,
    lifecycle: &str,
    payload: Value,
    invocation: &Invocation,
) -> Result<ResourceWrite, CapabilityError> {
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        deps.engine_host
            .update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: existing.resource.current_version_id,
                lifecycle: Some(lifecycle.to_owned()),
                payload,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        return Ok(ResourceWrite { resource_id });
    }
    create_lifecycle_resource(deps, kind, resource_id, lifecycle, payload, invocation).await
}

pub(super) async fn update_status_resource(
    deps: &Deps,
    resource_id: &str,
    lifecycle: &str,
    payload: Value,
    invocation: &Invocation,
) -> Result<ResourceWrite, CapabilityError> {
    let existing = deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "WORKER_LIFECYCLE_RESOURCE_NOT_FOUND".to_owned(),
            message: format!("missing lifecycle resource {resource_id}"),
        })?;
    deps.engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.to_owned(),
            expected_current_version_id: existing.resource.current_version_id,
            lifecycle: Some(lifecycle.to_owned()),
            payload,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(ResourceWrite {
        resource_id: resource_id.to_owned(),
    })
}

pub(super) async fn current_resource_payload(
    deps: &Deps,
    resource_id: &str,
) -> Result<Value, CapabilityError> {
    let inspection = deps
        .engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "WORKER_LIFECYCLE_RESOURCE_NOT_FOUND".to_owned(),
            message: format!("missing lifecycle resource {resource_id}"),
        })?;
    let version = inspection
        .versions
        .iter()
        .find(|version| {
            Some(&version.version_id) == inspection.resource.current_version_id.as_ref()
        })
        .or_else(|| inspection.versions.last())
        .ok_or_else(|| internal_error("lifecycle resource has no versions"))?;
    Ok(version.payload.clone())
}

pub(super) async fn update_package_and_installation_status(
    deps: &Deps,
    invocation: &Invocation,
    package: &ValidatedPackage,
    status: &str,
    reason: Option<String>,
) -> Result<(ResourceWrite, ResourceWrite), CapabilityError> {
    let package_write = update_status_resource(
        deps,
        &package_resource_id(&package.manifest),
        status,
        package_payload(package, status),
        invocation,
    )
    .await?;
    let installation_write = update_status_resource(
        deps,
        &installation_resource_id(&package.manifest),
        status,
        installation_payload(
            package,
            &package_write.resource_id,
            status,
            invocation,
            reason,
        ),
        invocation,
    )
    .await?;
    Ok((package_write, installation_write))
}

pub(super) async fn link_if_possible(
    deps: &Deps,
    source_resource_id: &str,
    target_resource_id: &str,
    relation: &str,
    invocation: &Invocation,
) -> Result<(), CapabilityError> {
    match deps
        .engine_host
        .link_resources(LinkResources {
            source_resource_id: source_resource_id.to_owned(),
            target_resource_id: target_resource_id.to_owned(),
            relation: relation.to_owned(),
            metadata: json!({"source": WORKER}),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
    {
        Ok(_) => Ok(()),
        Err(crate::engine::EngineError::PolicyViolation(message))
            if message.contains("already exists") =>
        {
            Ok(())
        }
        Err(error) => Err(engine_error(error)),
    }
}

pub(super) async fn publish_lifecycle_event(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    payload: Value,
) -> Result<StreamCursor, CapabilityError> {
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: WORKER_LIFECYCLE_TOPIC.to_owned(),
            payload: json!({
                "type": event_type,
                "payload": payload,
                "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
                "actorId": invocation.causal_context.actor_id.as_str(),
            }),
            visibility: VisibilityScope::System,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)
}

fn scope_for_invocation(invocation: &Invocation) -> EngineResourceScope {
    invocation
        .causal_context
        .workspace_id
        .clone()
        .map(EngineResourceScope::Workspace)
        .unwrap_or(EngineResourceScope::System)
}

pub(super) fn package_payload(package: &ValidatedPackage, status: &str) -> Value {
    json!({
        "schemaVersion": super::PACKAGE_SCHEMA_VERSION,
        "packageId": package.manifest.package_id,
        "packageVersion": package.manifest.package_version,
        "packageDigest": package.manifest.package_digest,
        "provenance": package.manifest.provenance,
        "source": package.manifest.source,
        "workerId": package.manifest.worker_id,
        "namespaceClaims": package.manifest.namespace_claims,
        "launchCommand": package.argv,
        "workingDirectory": package.working_directory.display().to_string(),
        "envAllowlist": package.env_keys,
        "expectedFunctions": package.manifest.expected_functions,
        "expectedTriggers": package.manifest.expected_triggers,
        "requestedGrants": package.manifest.requested_grants,
        "conformancePolicy": package.manifest.conformance_policy,
        "rollbackPolicy": package.manifest.rollback_policy,
        "manifest": package.manifest,
        "sourceRoot": package.source_root.display().to_string(),
        "status": status,
    })
}

pub(super) fn installation_payload(
    package: &ValidatedPackage,
    package_resource_id: &str,
    status: &str,
    invocation: &Invocation,
    reason: Option<String>,
) -> Value {
    let mut payload = json!({
        "packageId": package.manifest.package_id,
        "packageVersion": package.manifest.package_version,
        "packageDigest": package.manifest.package_digest,
        "workerId": package.manifest.worker_id,
        "packageResourceId": package_resource_id,
        "status": status,
        "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "rollbackRef": {
            "onFailure": package.manifest.rollback_policy.on_failure,
            "packageResourceId": package_resource_id,
        },
    });
    if let Some(reason) = reason
        && let Some(object) = payload.as_object_mut()
    {
        object.insert("reason".to_owned(), json!(reason));
    }
    payload
}

pub(super) fn json_patch_status(payload: &Value, invocation: &Invocation, status: &str) -> Value {
    let mut payload = payload.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("status".to_owned(), json!(status));
        object.insert(
            "updatedByInvocationId".to_owned(),
            json!(invocation.id.as_str()),
        );
    }
    payload
}

pub(super) fn package_resource_id(manifest: &WorkerPackageManifest) -> String {
    format!(
        "worker_package:{}:{}",
        manifest.package_id, manifest.package_version
    )
}

pub(super) fn installation_resource_id(manifest: &WorkerPackageManifest) -> String {
    format!(
        "worker_package_installation:{}:{}",
        manifest.package_id, manifest.package_version
    )
}

pub(super) fn proposal_resource_id(
    manifest: &WorkerPackageManifest,
    invocation_id: &InvocationId,
) -> String {
    format!(
        "worker_package_proposal:{}:{}:{}",
        manifest.package_id, manifest.package_version, invocation_id
    )
}

pub(super) fn launch_attempt_resource_id(
    manifest: &WorkerPackageManifest,
    invocation_id: &InvocationId,
) -> String {
    format!(
        "worker_launch_attempt:{}:{}:{}",
        manifest.package_id, manifest.package_version, invocation_id
    )
}

pub(super) fn conformance_resource_id(
    manifest: &WorkerPackageManifest,
    invocation_id: &InvocationId,
) -> String {
    format!(
        "worker_package_conformance_report:{}:{}:{}",
        manifest.package_id, manifest.package_version, invocation_id
    )
}

fn worker_id() -> Result<WorkerId, CapabilityError> {
    WorkerId::new(WORKER).map_err(engine_error)
}

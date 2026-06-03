//! self-extension domain worker.
//!
//! This module owns the user-approved boundary that lets an agent perform
//! local capability creation and repair inside one workspace. The approval
//! target is product-facing; the handler derives the underlying engine grant
//! through `grant::derive`, and sandbox-created helpers consume that grant when
//! deriving their narrower worker grants.

use std::path::{Path, PathBuf};

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use serde_json::{Value, json};

use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, FunctionId, Invocation,
};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_string, require_string_param};

const WORKSPACE_AUTONOMY_SUMMARY: &str = "Safe in this workspace";

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::domains::worker::domain_worker_module(
        "self_extension",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}

async fn grant_workspace_autonomy(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    let workspace_id = non_empty_param(payload, "workspaceId")?;
    let workspace_path =
        canonical_workspace_path(&require_string_param(Some(payload), "workspacePath")?)?;
    let session_id = opt_string(Some(payload), "sessionId")
        .or_else(|| invocation.causal_context.session_id.clone());
    let reason = opt_string(Some(payload), "reason").unwrap_or_else(|| {
        "Create, test, and repair local capabilities in this workspace.".to_owned()
    });

    let mut context = CausalContext::new(
        ActorId::new("self-extension-grant").map_err(engine_invalid_params)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_invalid_params)?,
        invocation.causal_context.trace_id.clone(),
    )
    .with_scope("grant.write")
    .with_parent_invocation(invocation.id.clone())
    .with_idempotency_key(format!(
        "self-extension-workspace-autonomy:{}",
        invocation.id
    ));
    if let Some(session_id) = session_id.clone() {
        context = context.with_session_id(session_id);
    }
    context = context.with_workspace_id(workspace_id.clone());

    let grant_payload = json!({
        "parentGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "subjectActorId": invocation.causal_context.actor_id.as_str(),
        "allowedCapabilities": ["*"],
        "allowedNamespaces": ["*"],
        "allowedAuthorityScopes": ["*"],
        "allowedResourceKinds": ["*"],
        "resourceSelectors": [format!("workspace:{workspace_id}")],
        "fileRoots": [workspace_path.display().to_string()],
        "networkPolicy": "loopback",
        "maxRisk": "high",
        "budget": {
            "class": "workspace_autonomy",
            "workspaceId": workspace_id,
        },
        "canDelegate": true,
        "approvalRequired": false,
        "provenance": {
            "source": "self_extension::grant_workspace_autonomy",
            "parentInvocationId": invocation.id.as_str(),
            "workspaceId": workspace_id,
            "workspacePath": workspace_path.display().to_string(),
            "reason": reason,
        },
    });
    let result = deps
        .engine_host
        .invoke(
            Invocation::new_sync(
                FunctionId::new("grant::derive").map_err(engine_invalid_params)?,
                grant_payload,
                context,
            )
            .with_delivery_mode(DeliveryMode::Sync),
        )
        .await;
    if let Some(error) = result.error {
        return Err(engine_internal(error));
    }
    let grant = result
        .value
        .and_then(|value| value.get("grant").cloned())
        .ok_or_else(|| CapabilityError::Internal {
            message: "grant::derive did not return a grant".to_owned(),
        })?;
    Ok(json!({
        "status": "approved",
        "grantId": grant["grantId"],
        "grantRevision": grant["revision"],
        "workspaceId": workspace_id,
        "workspacePath": workspace_path.display().to_string(),
        "summary": WORKSPACE_AUTONOMY_SUMMARY,
        "allowedWork": [
            "Create local helper capabilities",
            "Test and repair local helper capabilities",
            "Reuse helper capabilities in this workspace"
        ],
        "nextActions": [
            "Create helper capability",
            "Test helper capability",
            "Inspect evidence"
        ],
        "grant": grant,
    }))
}

fn non_empty_param(payload: &Value, key: &str) -> Result<String, CapabilityError> {
    let value = require_string_param(Some(payload), key)?;
    if value.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: format!("Parameter '{key}' must not be empty"),
        });
    }
    Ok(value)
}

fn canonical_workspace_path(path: &str) -> Result<PathBuf, CapabilityError> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return Err(CapabilityError::InvalidParams {
            message: "workspacePath must be absolute".to_owned(),
        });
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("workspacePath must be an existing directory: {error}"),
        })?;
    if !canonical.is_dir() {
        return Err(CapabilityError::InvalidParams {
            message: "workspacePath must be an existing directory".to_owned(),
        });
    }
    Ok(canonical)
}

fn engine_invalid_params(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: error.to_string(),
    }
}

fn engine_internal(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{EngineHostHandle, TraceId};

    #[tokio::test]
    async fn workspace_autonomy_grant_derives_bounded_delegate_grant() {
        let dir = tempfile::tempdir().unwrap();
        let deps = Deps {
            engine_host: EngineHostHandle::new_in_memory().unwrap(),
        };
        let invocation = Invocation::new_sync(
            FunctionId::new("self_extension::grant_workspace_autonomy").unwrap(),
            json!({
                "workspaceId": "workspace-self-extension-test",
                "workspacePath": dir.path().display().to_string(),
                "reason": "test local helper creation"
            }),
            CausalContext::new(
                ActorId::new("agent:workspace-self-extension-test").unwrap(),
                ActorKind::Agent,
                AuthorityGrantId::new("agent-capability-runtime").unwrap(),
                TraceId::new("trace-self-extension-test").unwrap(),
            )
            .with_scope("self_extension.write")
            .with_session_id("session-self-extension-test")
            .with_workspace_id("workspace-self-extension-test")
            .with_idempotency_key("self-extension-test-key"),
        );

        let value = grant_workspace_autonomy(&invocation, &deps)
            .await
            .expect("workspace autonomy grant should derive");
        let grant = &value["grant"];

        assert_eq!(value["status"], "approved");
        assert_eq!(value["summary"], WORKSPACE_AUTONOMY_SUMMARY);
        assert_eq!(grant["parentGrantId"], "agent-capability-runtime");
        assert_eq!(
            grant["subjectActorId"],
            "agent:workspace-self-extension-test"
        );
        assert_eq!(
            grant["resourceSelectors"],
            json!(["workspace:workspace-self-extension-test"])
        );
        assert_eq!(
            grant["fileRoots"],
            json!([dir.path().canonicalize().unwrap().display().to_string()])
        );
        assert_eq!(grant["networkPolicy"], "loopback");
        assert_eq!(grant["canDelegate"], true);
        assert_eq!(grant["approvalRequired"], false);
        assert_eq!(
            grant["provenance"]["source"],
            "self_extension::grant_workspace_autonomy"
        );
    }

    #[test]
    fn workspace_path_must_be_absolute_existing_directory() {
        let error = canonical_workspace_path("relative/path").unwrap_err();
        assert!(error.to_string().contains("absolute"));

        let error = canonical_workspace_path("/definitely/missing/tron/workspace").unwrap_err();
        assert!(error.to_string().contains("existing directory"));
    }
}

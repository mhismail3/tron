//! Decision and evidence resource creation helpers for module lifecycle operations.

use super::*;

pub(super) struct EvidenceCreation {
    pub(super) resource: EngineResource,
    pub(super) reference: Value,
}

impl ModulePrimitiveHandler {
    pub(super) fn create_decision_resource(
        &self,
        invocation: &Invocation,
        payload: Value,
        scope: Option<EngineResourceScope>,
        target_resource_id: &str,
        relation: &str,
    ) -> Result<EvidenceCreation> {
        reject_raw_secrets(&payload)?;
        let resource = self.create_resource(CreateResource {
            resource_id: None,
            kind: "decision".to_owned(),
            schema_id: None,
            scope: scope.unwrap_or(EngineResourceScope::System),
            owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("final".to_owned()),
            policy: json!({"managedBy": "module"}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        link_if_possible(
            self,
            &resource.resource_id,
            target_resource_id,
            relation,
            invocation,
        );
        Ok(EvidenceCreation {
            reference: resource_ref_from_resource(&resource, "decision"),
            resource,
        })
    }

    pub(super) fn create_evidence_resource(
        &self,
        invocation: &Invocation,
        summary: &str,
        source: &str,
        target_resource_id: &str,
        metadata: Value,
    ) -> Result<EvidenceCreation> {
        let payload = json!({
            "summary": summary,
            "source": source,
            "resourceRef": target_resource_id,
            "metadata": metadata,
        });
        reject_raw_secrets(&payload)?;
        let resource = self.create_resource(CreateResource {
            resource_id: None,
            kind: "evidence".to_owned(),
            schema_id: None,
            scope: EngineResourceScope::System,
            owner_worker_id: WorkerId::new(MODULE_WORKER_ID)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("accepted".to_owned()),
            policy: json!({"managedBy": "module"}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        link_if_possible(
            self,
            &resource.resource_id,
            target_resource_id,
            "evidence_for",
            invocation,
        );
        Ok(EvidenceCreation {
            reference: resource_ref_from_resource(&resource, "evidence"),
            resource,
        })
    }
}

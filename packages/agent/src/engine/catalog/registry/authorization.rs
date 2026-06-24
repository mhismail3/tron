//! Catalog authority grant validation helpers.

use chrono::Utc;

use crate::engine::authority::grants::EngineGrantLifecycle;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::types::{FunctionDefinition, WorkerDefinition};

use super::LiveCatalog;
use super::output_contract::output_contract_resource_kinds;

impl LiveCatalog {
    pub(super) fn validate_worker_grant(&self, definition: &WorkerDefinition) -> Result<()> {
        let grants = self
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?;
        let grant = grants
            .inspect(&definition.authority_grant)?
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "worker {} authority grant {} not found",
                    definition.id, definition.authority_grant
                ))
            })?;
        if grant.lifecycle != EngineGrantLifecycle::Active {
            return Err(EngineError::PolicyViolation(format!(
                "worker {} authority grant {} is not active",
                definition.id, definition.authority_grant
            )));
        }
        if let Some(expires_at) = grant.expires_at
            && expires_at <= Utc::now()
        {
            return Err(EngineError::PolicyViolation(format!(
                "worker {} authority grant {} is expired",
                definition.id, definition.authority_grant
            )));
        }
        for namespace in &definition.namespace_claims {
            if !allows_item(&grant.allowed_namespaces, namespace) {
                return Err(EngineError::PolicyViolation(format!(
                    "worker {} namespace {namespace} exceeds authority grant {}",
                    definition.id, definition.authority_grant
                )));
            }
        }
        Ok(())
    }

    pub(super) fn validate_function_worker_grant(
        &self,
        definition: &FunctionDefinition,
        owner: &WorkerDefinition,
    ) -> Result<()> {
        let grants = self
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?;
        let grant = grants.inspect(&owner.authority_grant)?.ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "function {} worker grant {} not found",
                definition.id, owner.authority_grant
            ))
        })?;
        if grant.lifecycle != EngineGrantLifecycle::Active {
            return Err(EngineError::PolicyViolation(format!(
                "function {} worker grant {} is not active",
                definition.id, owner.authority_grant
            )));
        }
        if definition.risk_level > grant.max_risk {
            return Err(EngineError::PolicyViolation(format!(
                "function {} risk {:?} exceeds worker grant {} max risk {:?}",
                definition.id, definition.risk_level, owner.authority_grant, grant.max_risk
            )));
        }
        if !allows_item(&grant.allowed_capabilities, definition.id.as_str())
            && !allows_item(&grant.allowed_namespaces, definition.id.namespace())
        {
            return Err(EngineError::PolicyViolation(format!(
                "function {} exceeds worker grant {} capabilities",
                definition.id, owner.authority_grant
            )));
        }
        for scope in &definition.required_authority.scopes {
            if !allows_item(&grant.allowed_authority_scopes, scope) {
                return Err(EngineError::PolicyViolation(format!(
                    "function {} required authority {scope} exceeds worker grant {}",
                    definition.id, owner.authority_grant
                )));
            }
        }
        for kind in output_contract_resource_kinds(&definition.output_contract) {
            if kind != "*" && !allows_item(&grant.allowed_resource_kinds, &kind) {
                return Err(EngineError::PolicyViolation(format!(
                    "function {} output resource kind {kind} exceeds worker grant {}",
                    definition.id, owner.authority_grant
                )));
            }
        }
        Ok(())
    }
}

fn allows_item(allowed: &[String], value: &str) -> bool {
    allowed.iter().any(|item| item == "*" || item == value)
}

//! Ephemeral custody for worker activation bundles.
//!
//! This vault is intentionally process-memory only. It bridges the immediate
//! `worker::issue_activation` result and a later governed
//! `worker::launch_activation` stdin handoff without giving SQLite, resources,
//! streams, queues, logs, argv, or env access to the activation bundle.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, InvocationId, TraceId, WorkerId};

/// Safe metadata about an activation bundle held by the vault.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkerActivationBundleMetadata {
    /// Durable activation resource id.
    pub activation_resource_id: String,
    /// Worker id bound into the bundle.
    pub worker_id: WorkerId,
    /// Function id the worker is expected to register.
    pub function_id: FunctionId,
    /// RFC3339 expiry from the activation resource.
    pub expires_at: DateTime<Utc>,
    /// Fingerprint of the scoped worker token.
    pub token_fingerprint: String,
    /// Fingerprint of the exact stdin payload.
    pub bundle_fingerprint: String,
    /// Byte count of the exact stdin payload.
    pub bundle_byte_count: usize,
    /// Trace that issued the bundle.
    pub issued_trace_id: TraceId,
    /// Invocation that issued the bundle.
    pub issued_invocation_id: InvocationId,
}

/// One consumed bundle, including secret stdin bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConsumedWorkerActivationBundle {
    /// Safe metadata retained by callers.
    pub metadata: WorkerActivationBundleMetadata,
    /// Secret bytes to write once to child stdin.
    pub stdin_bytes: Vec<u8>,
}

#[derive(Clone, Debug)]
struct VaultEntry {
    metadata: WorkerActivationBundleMetadata,
    stdin_bytes: Vec<u8>,
}

/// Process-memory activation bundle store.
#[derive(Clone, Debug, Default)]
pub struct WorkerActivationBundleVault {
    entries: BTreeMap<String, VaultEntry>,
}

impl WorkerActivationBundleVault {
    /// Create an empty vault.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Store a live bundle until its activation expiry.
    pub fn store(
        &mut self,
        activation_resource_id: String,
        worker_id: WorkerId,
        function_id: FunctionId,
        expires_at: DateTime<Utc>,
        token_fingerprint: String,
        activation_bundle: &Value,
        issued_trace_id: TraceId,
        issued_invocation_id: InvocationId,
    ) -> Result<WorkerActivationBundleMetadata> {
        self.purge_expired(Utc::now());
        let stdin_bytes = serde_json::to_vec(activation_bundle).map_err(|error| {
            EngineError::PolicyViolation(format!("activation bundle serialization failed: {error}"))
        })?;
        let metadata = WorkerActivationBundleMetadata {
            activation_resource_id: activation_resource_id.clone(),
            worker_id,
            function_id,
            expires_at,
            token_fingerprint,
            bundle_fingerprint: fingerprint_bytes(&stdin_bytes),
            bundle_byte_count: stdin_bytes.len(),
            issued_trace_id,
            issued_invocation_id,
        };
        self.entries.insert(
            activation_resource_id,
            VaultEntry {
                metadata: metadata.clone(),
                stdin_bytes,
            },
        );
        Ok(metadata)
    }

    /// Inspect safe metadata for tests and launch preflight.
    #[must_use]
    pub fn metadata(&self, activation_resource_id: &str) -> Option<WorkerActivationBundleMetadata> {
        self.entries
            .get(activation_resource_id)
            .filter(|entry| entry.metadata.expires_at > Utc::now())
            .map(|entry| entry.metadata.clone())
    }

    /// Consume a bundle exactly once.
    pub fn consume(
        &mut self,
        activation_resource_id: &str,
    ) -> Result<ConsumedWorkerActivationBundle> {
        self.purge_expired(Utc::now());
        let Some(entry) = self.entries.remove(activation_resource_id) else {
            return Err(EngineError::PolicyViolation(format!(
                "activation bundle {activation_resource_id} is missing, expired, or already consumed"
            )));
        };
        Ok(ConsumedWorkerActivationBundle {
            metadata: entry.metadata,
            stdin_bytes: entry.stdin_bytes,
        })
    }

    /// Purge expired entries.
    pub fn purge_expired(&mut self, now: DateTime<Utc>) {
        self.entries
            .retain(|_, entry| entry.metadata.expires_at > now);
    }
}

fn fingerprint_bytes(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

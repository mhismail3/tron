pub(super) use super::super::super::embeddings::{EmbeddingProvider, HashEmbeddingProvider};
pub(super) use super::super::*;
pub(super) use crate::domains::capability::types::{
    CapabilityPauseRecord, CapabilityProgramRunRecord, CapabilityRunRecord,
};
pub(super) use crate::engine::{
    AuthorityGrantId, FunctionId, TriggerId, TriggerTypeId, VisibilityScope, WorkerId,
};

use std::sync::atomic::{AtomicUsize, Ordering};

pub(super) use chrono::Utc;
pub(super) use serde_json::json;

pub(super) struct FailingEmbeddingProvider;

impl EmbeddingProvider for FailingEmbeddingProvider {
    fn model_id(&self) -> &'static str {
        "test:failing"
    }

    fn dimensions(&self) -> usize {
        64
    }

    fn embed(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        Err("embedding assets unavailable".to_owned())
    }
}

pub(super) struct CountingEmbeddingProvider {
    calls: AtomicUsize,
    max_batch: AtomicUsize,
}

impl CountingEmbeddingProvider {
    pub(super) fn new() -> Self {
        Self {
            calls: AtomicUsize::new(0),
            max_batch: AtomicUsize::new(0),
        }
    }

    pub(super) fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }

    pub(super) fn max_batch(&self) -> usize {
        self.max_batch.load(Ordering::SeqCst)
    }
}

impl EmbeddingProvider for CountingEmbeddingProvider {
    fn model_id(&self) -> &'static str {
        "test:counting"
    }

    fn dimensions(&self) -> usize {
        64
    }

    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.max_batch.fetch_max(texts.len(), Ordering::SeqCst);
        Ok(texts
            .iter()
            .map(|text| {
                let mut vector = vec![0.0; 64];
                vector[text.len() % 64] = 1.0;
                vector
            })
            .collect())
    }
}

pub(super) fn test_function(id: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        FunctionId::new(id).expect("function id"),
        WorkerId::new(id.split("::").next().expect("namespace")).expect("worker id"),
        "Searchable test function",
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_request_schema(json!({
        "type": "object",
        "properties": {"path": {"type": "string"}},
        "required": ["path"]
    }))
}

pub(super) fn session_generated_function(id: &str, worker: &str) -> FunctionDefinition {
    let namespace = id
        .split_once("::")
        .map(|(namespace, _)| namespace)
        .unwrap_or(id);
    let local_name = id.split_once("::").map(|(_, local)| local).unwrap_or(id);
    let mut function = FunctionDefinition::new(
        FunctionId::new(id).expect("function id"),
        WorkerId::new(worker).expect("worker id"),
        "Live external worker function",
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_request_schema(json!({
        "type": "object",
        "additionalProperties": true
    }))
    .with_response_schema(json!({
        "type": "object",
        "additionalProperties": true
    }));
    function.metadata = json!({
        "contractId": id,
        "implementationId": format!("session_generated.{namespace}.{local_name}"),
        "pluginId": format!("session_generated.{worker}"),
        "trustTier": "session_generated",
        "contextPrimerLevel": "catalog",
        "runtimeRequirements": {
            "workerKind": "external",
            "deliveryModes": ["Sync"]
        },
        "signatureStatus": "session_scoped",
        "conformanceState": "healthy"
    });
    function
}

pub(super) fn manual_trigger(id: &str, worker: &str, target: &str) -> TriggerDefinition {
    let mut trigger = TriggerDefinition::new(
        TriggerId::new(id).expect("trigger id"),
        WorkerId::new(worker).expect("worker id"),
        TriggerTypeId::new("manual").expect("trigger type"),
        FunctionId::new(target).expect("target function"),
        AuthorityGrantId::new("external-grant").expect("authority grant"),
    );
    trigger.visibility = VisibilityScope::System;
    trigger
}

pub(super) fn sync_without_vectors(
    store: &mut dyn CapabilityRegistryStore,
    snapshot: &CapabilityRegistrySnapshot,
) {
    let policy = CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    };
    let provider = HashEmbeddingProvider::new(64);
    store
        .sync_snapshot(snapshot, &provider, &policy)
        .expect("sync snapshot");
}

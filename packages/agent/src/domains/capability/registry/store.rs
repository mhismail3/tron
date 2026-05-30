//! Concrete registry persistence for capability projection state.
//!
//! The registry root owns catalog projection and selection semantics. This
//! module owns the durable and in-memory store implementations, schema,
//! redaction, and vector persistence details so persistence cannot accumulate
//! model-facing search or recipe policy.

mod memory;
mod projection;
mod schema;
mod sqlite;
mod sqlite_runtime;

use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use super::super::embeddings::EmbeddingProvider;
use super::index::CapabilityIndexSearchResult;
use super::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot, CapabilitySearchFilters,
    CapabilitySearchPolicy,
};
use crate::domains::capability::types::{
    CapabilityBindingDecision, CapabilityBindingRecord, CapabilityIndexStatus,
    CapabilityInspectionHandle, CapabilityPauseRecord, CapabilityPluginManifest,
    CapabilityProgramRunRecord, CapabilityRunRecord,
};

pub(crate) use memory::InMemoryCapabilityRegistryStore;
pub(crate) use sqlite::SqliteCapabilityRegistryStore;

pub(crate) type SharedCapabilityRegistryStore = Arc<Mutex<Box<dyn CapabilityRegistryStore>>>;

pub(crate) fn open_capability_registry_store(
    engine_ledger_path: Option<PathBuf>,
) -> Result<SharedCapabilityRegistryStore, String> {
    let store: Box<dyn CapabilityRegistryStore> = match engine_ledger_path {
        Some(path) => Box::new(SqliteCapabilityRegistryStore::open(&path)?),
        None => Box::new(InMemoryCapabilityRegistryStore::default()),
    };
    Ok(Arc::new(Mutex::new(store)))
}

pub(crate) trait CapabilityRegistryStore: Send {
    fn sync_snapshot(
        &mut self,
        snapshot: &CapabilityRegistrySnapshot,
        embedding_provider: &dyn EmbeddingProvider,
        policy: &CapabilitySearchPolicy,
    ) -> Result<CapabilityIndexStatus, String>;

    fn search(
        &self,
        query: &str,
        filters: &CapabilitySearchFilters,
        policy: &CapabilitySearchPolicy,
        limit: usize,
        embedding_provider: &dyn EmbeddingProvider,
    ) -> Result<CapabilityIndexSearchResult, String>;

    fn active_binding(
        &self,
        contract_id: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
    ) -> Result<Option<CapabilityBindingRecord>, String>;

    fn implementation_conformance_state(
        &self,
        implementation_id: &str,
    ) -> Result<Option<String>, String>;

    fn record_inspection(
        &mut self,
        handle: &CapabilityInspectionHandle,
        entry: &CapabilityRegistryEntry,
        decision: &CapabilityBindingDecision,
    ) -> Result<(), String>;

    fn validate_inspection(
        &self,
        handle: &str,
        entry: &CapabilityRegistryEntry,
    ) -> Result<bool, String>;

    fn record_binding_decision(
        &mut self,
        decision: &CapabilityBindingDecision,
        selected_entry: &CapabilityRegistryEntry,
    ) -> Result<(), String>;

    fn record_audit_event(
        &mut self,
        event_type: &str,
        trace_id: Option<&str>,
        payload: Value,
    ) -> Result<(), String>;

    fn record_program_run(&mut self, record: &CapabilityProgramRunRecord) -> Result<(), String>;

    fn record_pause(&mut self, record: &CapabilityPauseRecord) -> Result<(), String>;

    fn resolve_pause(
        &mut self,
        pause_id: &str,
        status: &str,
        resolution: Value,
    ) -> Result<Option<CapabilityPauseRecord>, String>;

    fn record_run(&mut self, record: &CapabilityRunRecord) -> Result<(), String>;

    fn update_run_status(
        &mut self,
        run_id: &str,
        status: &str,
        details: Value,
    ) -> Result<Option<CapabilityRunRecord>, String>;

    fn program_run_query(
        &self,
        trace_id: Option<&str>,
        status: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String>;

    fn admin_status(&self) -> Result<Value, String>;

    fn registry_snapshot(&self) -> Result<Value, String>;

    fn audit_query(
        &self,
        event_type: Option<&str>,
        trace_id: Option<&str>,
        limit: usize,
        reveal_payloads: bool,
    ) -> Result<Value, String>;

    fn list_bindings(&self) -> Result<Value, String>;

    fn upsert_binding(
        &mut self,
        contract_id: &str,
        scope_kind: &str,
        scope_value: &str,
        selected_implementation: &str,
        selection_policy: &str,
        secondary_implementations: &[String],
        priority: i64,
        enabled: bool,
    ) -> Result<(), String>;

    fn list_plugins(&self) -> Result<Value, String>;

    fn plugin_inspect(&self, plugin_id: &str) -> Result<Option<Value>, String>;

    fn upsert_plugin_manifest(
        &mut self,
        manifest: &CapabilityPluginManifest,
        conformance_state: &str,
        catalog_revision: u64,
    ) -> Result<(), String>;

    fn set_plugin_state(&mut self, plugin_id: &str, state: &str) -> Result<(), String>;

    fn set_implementation_state(
        &mut self,
        implementation_id: &str,
        state: &str,
    ) -> Result<(), String>;
}

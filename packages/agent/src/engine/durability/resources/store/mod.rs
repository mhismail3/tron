//! In-memory and SQLite resource store implementations.

use std::path::Path;

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use uuid::Uuid;

use super::definitions::type_definition_from_request;
use super::types::*;
use super::validation::{
    ensure_lifecycle, ensure_relation, validate_create_request, validate_link_request,
    validate_list_filter, validate_resource_payload, validate_token, validate_type_request,
    validate_update_request,
};
use super::versions::payload_hash;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{InvocationId, TraceId};

mod memory;
mod sqlite_codec;
#[cfg(test)]
mod tests;

pub use memory::InMemoryEngineResourceStore;
use sqlite_codec::{
    RESOURCE_SQLITE_SCHEMA, collect_rows, json_string, resource_scope_workspace, row_to_resource,
    row_to_resource_event, row_to_resource_link, row_to_resource_version, row_to_type_definition,
    sqlite_err,
};

fn resource_event(
    resource_id: &str,
    event_type: &str,
    payload: Value,
    invocation_id: Option<InvocationId>,
    trace_id: TraceId,
) -> EngineResourceEvent {
    EngineResourceEvent {
        event_id: generated_id("revt"),
        resource_id: resource_id.to_owned(),
        event_type: event_type.to_owned(),
        payload,
        invocation_id,
        trace_id,
        occurred_at: Utc::now(),
    }
}

fn generated_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::now_v7())
}

/// SQLite-backed resource store.
pub struct SqliteEngineResourceStore {
    conn: Connection,
}

impl SqliteEngineResourceStore {
    /// Open a resource store in the engine ledger database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("resource.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        crate::shared::storage::apply_runtime_pragmas(&self.conn)
            .map_err(|err| sqlite_err("resource.storage_pragmas", err.to_string()))?;
        crate::shared::storage::ensure_storage_schema(&self.conn)
            .map_err(|err| sqlite_err("resource.storage_schema", err.to_string()))?;
        self.conn
            .execute_batch(RESOURCE_SQLITE_SCHEMA)
            .map_err(|err| sqlite_err("resource.init", err.to_string()))
    }

    /// Register or update one resource type definition.
    pub fn register_type(
        &mut self,
        request: RegisterResourceType,
    ) -> Result<EngineResourceTypeDefinition> {
        validate_type_request(&request)?;
        let now = Utc::now();
        let existing = self.get_type(&request.kind)?;
        let revision = existing
            .as_ref()
            .map_or(1, |definition| definition.revision.saturating_add(1));
        let created_at = existing
            .as_ref()
            .map_or(now, |definition| definition.created_at);
        let definition = type_definition_from_request(request, revision, created_at, now);
        self.conn
            .execute(
                "INSERT INTO engine_resource_type_definitions
                 (kind, schema_id, schema_json, lifecycle_states_json, versioning_mode,
                  allowed_link_relations_json, default_retention_json, redaction_rules_json,
                  materialization_rules_json, required_capabilities_json, owner_worker_id,
                  revision, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                 ON CONFLICT(kind) DO UPDATE SET
                   schema_id = excluded.schema_id,
                   schema_json = excluded.schema_json,
                   lifecycle_states_json = excluded.lifecycle_states_json,
                   versioning_mode = excluded.versioning_mode,
                   allowed_link_relations_json = excluded.allowed_link_relations_json,
                   default_retention_json = excluded.default_retention_json,
                   redaction_rules_json = excluded.redaction_rules_json,
                   materialization_rules_json = excluded.materialization_rules_json,
                   required_capabilities_json = excluded.required_capabilities_json,
                   owner_worker_id = excluded.owner_worker_id,
                   revision = excluded.revision,
                   updated_at = excluded.updated_at",
                params![
                    definition.kind,
                    definition.schema_id,
                    json_string(&definition.schema, "type.schema")?,
                    json_string(&definition.lifecycle_states, "type.lifecycle_states")?,
                    definition.versioning_mode.as_str(),
                    json_string(
                        &definition.allowed_link_relations,
                        "type.allowed_link_relations"
                    )?,
                    json_string(&definition.default_retention, "type.default_retention")?,
                    json_string(&definition.redaction_rules, "type.redaction_rules")?,
                    json_string(
                        &definition.materialization_rules,
                        "type.materialization_rules"
                    )?,
                    json_string(
                        &definition.required_capabilities,
                        "type.required_capabilities"
                    )?,
                    definition.owner_worker_id.as_str(),
                    definition.revision,
                    definition.created_at.to_rfc3339(),
                    definition.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.register_type", err.to_string()))?;
        Ok(definition)
    }

    /// Read one resource type definition.
    pub fn get_type(&self, kind: &str) -> Result<Option<EngineResourceTypeDefinition>> {
        validate_token("resource kind", kind)?;
        self.conn
            .query_row(
                "SELECT kind, schema_id, schema_json, lifecycle_states_json, versioning_mode,
                        allowed_link_relations_json, default_retention_json, redaction_rules_json,
                        materialization_rules_json, required_capabilities_json, owner_worker_id,
                        revision, created_at, updated_at
                 FROM engine_resource_type_definitions WHERE kind = ?1",
                params![kind],
                row_to_type_definition,
            )
            .optional()
            .map_err(|err| sqlite_err("resource.get_type", err.to_string()))
    }

    /// List registered resource type definitions.
    pub fn list_types(&self) -> Result<Vec<EngineResourceTypeDefinition>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT kind, schema_id, schema_json, lifecycle_states_json, versioning_mode,
                        allowed_link_relations_json, default_retention_json, redaction_rules_json,
                        materialization_rules_json, required_capabilities_json, owner_worker_id,
                        revision, created_at, updated_at
                 FROM engine_resource_type_definitions ORDER BY kind",
            )
            .map_err(|err| sqlite_err("resource.list_types.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], row_to_type_definition)
            .map_err(|err| sqlite_err("resource.list_types", err.to_string()))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|err| sqlite_err("resource.list_types.row", err.to_string()))
    }

    /// Create a resource.
    pub fn create(&mut self, request: CreateResource) -> Result<EngineResource> {
        validate_create_request(&request)?;
        let type_definition = self.require_type(&request.kind)?;
        let lifecycle = request
            .lifecycle
            .clone()
            .unwrap_or_else(|| type_definition.lifecycle_states[0].clone());
        ensure_lifecycle(&type_definition, &lifecycle)?;
        let schema_id = request
            .schema_id
            .clone()
            .unwrap_or_else(|| type_definition.schema_id.clone());
        if schema_id != type_definition.schema_id {
            return Err(EngineError::PolicyViolation(format!(
                "resource kind {} requires schema {}",
                request.kind, type_definition.schema_id
            )));
        }
        let resource_id = request
            .resource_id
            .clone()
            .unwrap_or_else(|| generated_id("res"));
        let exists = self
            .conn
            .query_row(
                "SELECT 1 FROM engine_resources WHERE resource_id = ?1",
                params![resource_id],
                |_row| Ok(()),
            )
            .optional()
            .map_err(|err| sqlite_err("resource.exists", err.to_string()))?
            .is_some();
        if exists {
            return Err(EngineError::PolicyViolation(format!(
                "resource {resource_id} already exists"
            )));
        }
        if let Some(payload) = &request.initial_payload {
            validate_resource_payload(&type_definition, payload)?;
        }
        let now = Utc::now();
        let mut resource = EngineResource {
            resource_id: resource_id.clone(),
            kind: request.kind.clone(),
            schema_id,
            scope: request.scope.clone(),
            owner_worker_id: request.owner_worker_id.clone(),
            owner_actor_id: request.owner_actor_id.clone(),
            lifecycle,
            policy: request.policy.clone(),
            current_version_id: None,
            trace_id: request.trace_id.clone(),
            created_by_invocation_id: request.invocation_id.clone(),
            created_at: now,
            updated_at: now,
        };
        self.insert_resource(&resource)?;
        self.record_event(resource_event(
            &resource_id,
            "resource.created",
            json!({"kind": resource.kind, "lifecycle": resource.lifecycle}),
            request.invocation_id.clone(),
            request.trace_id.clone(),
        ))?;
        if let Some(payload) = request.initial_payload {
            let version = self.append_version_inner(
                &resource_id,
                None,
                None,
                payload,
                EngineResourceVersionState::Available,
                request.locations,
                request.trace_id,
                request.invocation_id,
            )?;
            resource.current_version_id = Some(version.version_id);
            resource.updated_at = Utc::now();
            self.update_resource_pointer(&resource)?;
        }
        Ok(resource)
    }

    /// Update one resource through compare-and-set.
    pub fn update(&mut self, request: UpdateResource) -> Result<EngineResourceVersion> {
        validate_update_request(&request)?;
        let resource = self.require_resource(&request.resource_id)?;
        let definition = self.require_type(&resource.kind)?;
        if let Some(lifecycle) = &request.lifecycle {
            ensure_lifecycle(&definition, lifecycle)?;
        }
        if resource.current_version_id != request.expected_current_version_id {
            return Err(EngineError::PolicyViolation(format!(
                "resource {} version conflict: expected {:?}, actual {:?}",
                request.resource_id,
                request.expected_current_version_id,
                resource.current_version_id
            )));
        }
        validate_resource_payload(&definition, &request.payload)?;
        self.append_version_inner(
            &request.resource_id,
            resource.current_version_id,
            request.lifecycle,
            request.payload,
            request.state.unwrap_or_default(),
            request.locations,
            request.trace_id,
            request.invocation_id,
        )
    }

    /// Link two resources.
    pub fn link(&mut self, request: LinkResources) -> Result<EngineResourceLink> {
        validate_link_request(&request)?;
        let source = self.require_resource(&request.source_resource_id)?;
        let _target = self.require_resource(&request.target_resource_id)?;
        let definition = self.require_type(&source.kind)?;
        ensure_relation(&definition, &request.relation)?;
        let link = EngineResourceLink {
            link_id: generated_id("link"),
            source_resource_id: request.source_resource_id,
            target_resource_id: request.target_resource_id,
            relation: request.relation,
            metadata: request.metadata,
            created_by_invocation_id: request.invocation_id.clone(),
            trace_id: request.trace_id.clone(),
            created_at: Utc::now(),
        };
        self.conn
            .execute(
                "INSERT INTO engine_resource_links
                 (link_id, source_resource_id, target_resource_id, relation, metadata_json,
                  created_by_invocation_id, trace_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    link.link_id,
                    link.source_resource_id,
                    link.target_resource_id,
                    link.relation,
                    json_string(&link.metadata, "resource_link.metadata")?,
                    link.created_by_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    link.trace_id.as_str(),
                    link.created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.link", err.to_string()))?;
        self.record_event(resource_event(
            &link.source_resource_id,
            "resource.linked",
            json!({
                "targetResourceId": link.target_resource_id,
                "relation": link.relation,
            }),
            request.invocation_id,
            request.trace_id,
        ))?;
        Ok(link)
    }

    /// Inspect one resource.
    pub fn inspect(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>> {
        validate_token("resource id", resource_id)?;
        let Some(resource) = self.get_resource(resource_id)? else {
            return Ok(None);
        };
        Ok(Some(EngineResourceInspection {
            versions: self.versions_for_resource(resource_id)?,
            outgoing_links: self.links_for_source(resource_id)?,
            incoming_links: self.links_for_target(resource_id)?,
            events: self.events_for_resource(resource_id)?,
            resource,
        }))
    }

    /// List resources.
    pub fn list(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        validate_list_filter(&filter)?;
        let mut resources = Vec::new();
        let mut stmt = self
            .conn
            .prepare(
                "SELECT resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                        owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                        created_by_invocation_id, created_at, updated_at
                 FROM engine_resources
                 ORDER BY updated_at DESC",
            )
            .map_err(|err| sqlite_err("resource.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], row_to_resource)
            .map_err(|err| sqlite_err("resource.list.query", err.to_string()))?;
        for row in rows {
            let resource = row.map_err(|err| sqlite_err("resource.list.row", err.to_string()))?;
            if filter
                .kind
                .as_ref()
                .is_none_or(|kind| &resource.kind == kind)
                && filter
                    .scope
                    .as_ref()
                    .is_none_or(|scope| &resource.scope == scope)
                && filter
                    .lifecycle
                    .as_ref()
                    .is_none_or(|lifecycle| &resource.lifecycle == lifecycle)
            {
                resources.push(resource);
                if resources.len() >= filter.limit.min(500) {
                    break;
                }
            }
        }
        Ok(resources)
    }

    /// List resources for crate-internal maintenance scans without the public
    /// response cap. Callers must keep their own mutation scope narrow.
    pub(in crate::engine) fn list_internal_scan(
        &self,
        filter: ListResources,
    ) -> Result<Vec<EngineResource>> {
        validate_list_filter(&filter)?;
        let mut resources = Vec::new();
        let mut stmt = self
            .conn
            .prepare(
                "SELECT resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                        owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                        created_by_invocation_id, created_at, updated_at
                 FROM engine_resources
                 ORDER BY updated_at DESC",
            )
            .map_err(|err| sqlite_err("resource.list_internal_scan.prepare", err.to_string()))?;
        let rows = stmt
            .query_map([], row_to_resource)
            .map_err(|err| sqlite_err("resource.list_internal_scan.query", err.to_string()))?;
        for row in rows {
            let resource =
                row.map_err(|err| sqlite_err("resource.list_internal_scan.row", err.to_string()))?;
            if filter
                .kind
                .as_ref()
                .is_none_or(|kind| &resource.kind == kind)
                && filter
                    .scope
                    .as_ref()
                    .is_none_or(|scope| &resource.scope == scope)
                && filter
                    .lifecycle
                    .as_ref()
                    .is_none_or(|lifecycle| &resource.lifecycle == lifecycle)
            {
                resources.push(resource);
                if resources.len() >= filter.limit {
                    break;
                }
            }
        }
        Ok(resources)
    }

    fn append_version_inner(
        &mut self,
        resource_id: &str,
        parent_version_id: Option<String>,
        lifecycle: Option<String>,
        payload: Value,
        state: EngineResourceVersionState,
        locations: Vec<EngineResourceLocation>,
        trace_id: TraceId,
        invocation_id: Option<InvocationId>,
    ) -> Result<EngineResourceVersion> {
        let mut resource = self.require_resource(resource_id)?;
        let version = EngineResourceVersion {
            version_id: generated_id("ver"),
            resource_id: resource_id.to_owned(),
            parent_version_id,
            content_hash: payload_hash(&payload)?,
            state,
            payload,
            locations,
            created_by_invocation_id: invocation_id.clone(),
            trace_id: trace_id.clone(),
            created_at: Utc::now(),
        };
        let owner_id = format!("resource_version:{}", version.version_id);
        let payload_json = crate::shared::storage::store_json_value(
            &self.conn,
            &version.payload,
            &crate::shared::storage::StorePayloadOptions::new(
                "engine_resource_version",
                owner_id,
                "payload",
                "correctness",
            )
            .with_scope(
                Some(trace_id.as_str().to_owned()),
                None,
                resource_scope_workspace(&resource.scope).map(str::to_owned),
            ),
        )
        .map_err(|err| sqlite_err("resource.version.payload", err.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO engine_resource_versions
                 (version_id, resource_id, parent_version_id, content_hash, version_state,
                  payload_json, locations_json, created_by_invocation_id, trace_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    version.version_id,
                    version.resource_id,
                    version.parent_version_id,
                    version.content_hash,
                    version.state.as_str(),
                    payload_json,
                    json_string(&version.locations, "resource_version.locations")?,
                    version
                        .created_by_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    version.trace_id.as_str(),
                    version.created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.version.insert", err.to_string()))?;
        if version.state.may_be_current() {
            resource.current_version_id = Some(version.version_id.clone());
        }
        if let Some(lifecycle) = lifecycle {
            resource.lifecycle = lifecycle;
        }
        resource.updated_at = Utc::now();
        self.update_resource_pointer(&resource)?;
        self.record_event(resource_event(
            resource_id,
            "resource.version.created",
            json!({
                "versionId": version.version_id,
                "contentHash": version.content_hash,
                "state": version.state.as_str(),
            }),
            invocation_id,
            trace_id,
        ))?;
        Ok(version)
    }

    fn insert_resource(&self, resource: &EngineResource) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_resources
                 (resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                  owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                  created_by_invocation_id, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    resource.resource_id,
                    resource.kind,
                    resource.schema_id,
                    resource.scope.kind(),
                    resource.scope.value(),
                    resource.owner_worker_id.as_str(),
                    resource.owner_actor_id.as_str(),
                    resource.lifecycle,
                    json_string(&resource.policy, "resource.policy")?,
                    resource.current_version_id,
                    resource.trace_id.as_str(),
                    resource
                        .created_by_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    resource.created_at.to_rfc3339(),
                    resource.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.insert", err.to_string()))?;
        Ok(())
    }

    fn update_resource_pointer(&self, resource: &EngineResource) -> Result<()> {
        self.conn
            .execute(
                "UPDATE engine_resources
                 SET lifecycle = ?2, policy_json = ?3, current_version_id = ?4, updated_at = ?5
                 WHERE resource_id = ?1",
                params![
                    resource.resource_id,
                    resource.lifecycle,
                    json_string(&resource.policy, "resource.policy")?,
                    resource.current_version_id,
                    resource.updated_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.pointer", err.to_string()))?;
        Ok(())
    }

    fn get_resource(&self, resource_id: &str) -> Result<Option<EngineResource>> {
        self.conn
            .query_row(
                "SELECT resource_id, kind, schema_id, scope_kind, scope_value, owner_worker_id,
                        owner_actor_id, lifecycle, policy_json, current_version_id, trace_id,
                        created_by_invocation_id, created_at, updated_at
                 FROM engine_resources WHERE resource_id = ?1",
                params![resource_id],
                row_to_resource,
            )
            .optional()
            .map_err(|err| sqlite_err("resource.get", err.to_string()))
    }

    fn require_type(&self, kind: &str) -> Result<EngineResourceTypeDefinition> {
        self.get_type(kind)?.ok_or_else(|| EngineError::NotFound {
            kind: "resource_type",
            id: kind.to_owned(),
        })
    }

    fn require_resource(&self, resource_id: &str) -> Result<EngineResource> {
        self.get_resource(resource_id)?
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: resource_id.to_owned(),
            })
    }

    fn versions_for_resource(&self, resource_id: &str) -> Result<Vec<EngineResourceVersion>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT version_id, resource_id, parent_version_id, content_hash, version_state,
                        payload_json, locations_json, created_by_invocation_id, trace_id, created_at
                 FROM engine_resource_versions WHERE resource_id = ?1 ORDER BY created_at ASC",
            )
            .map_err(|err| sqlite_err("resource.versions.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![resource_id], |row| {
                row_to_resource_version(&self.conn, row)
            })
            .map_err(|err| sqlite_err("resource.versions.query", err.to_string()))?;
        collect_rows(rows, "resource.versions.row")
    }

    fn links_for_source(&self, resource_id: &str) -> Result<Vec<EngineResourceLink>> {
        self.links_with_query(
            "SELECT link_id, source_resource_id, target_resource_id, relation, metadata_json,
                    created_by_invocation_id, trace_id, created_at
             FROM engine_resource_links WHERE source_resource_id = ?1 ORDER BY created_at ASC",
            resource_id,
            "resource.links.source",
        )
    }

    fn links_for_target(&self, resource_id: &str) -> Result<Vec<EngineResourceLink>> {
        self.links_with_query(
            "SELECT link_id, source_resource_id, target_resource_id, relation, metadata_json,
                    created_by_invocation_id, trace_id, created_at
             FROM engine_resource_links WHERE target_resource_id = ?1 ORDER BY created_at ASC",
            resource_id,
            "resource.links.target",
        )
    }

    fn links_with_query(
        &self,
        sql: &str,
        resource_id: &str,
        operation: &'static str,
    ) -> Result<Vec<EngineResourceLink>> {
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|err| sqlite_err(operation, err.to_string()))?;
        let rows = stmt
            .query_map(params![resource_id], row_to_resource_link)
            .map_err(|err| sqlite_err(operation, err.to_string()))?;
        collect_rows(rows, operation)
    }

    fn events_for_resource(&self, resource_id: &str) -> Result<Vec<EngineResourceEvent>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT event_id, resource_id, event_type, payload_json, invocation_id, trace_id,
                        occurred_at
                 FROM engine_resource_events WHERE resource_id = ?1 ORDER BY occurred_at ASC",
            )
            .map_err(|err| sqlite_err("resource.events.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![resource_id], row_to_resource_event)
            .map_err(|err| sqlite_err("resource.events.query", err.to_string()))?;
        collect_rows(rows, "resource.events.row")
    }

    fn record_event(&self, event: EngineResourceEvent) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_resource_events
                 (event_id, resource_id, event_type, payload_json, invocation_id, trace_id,
                  occurred_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    event.event_id,
                    event.resource_id,
                    event.event_type,
                    json_string(&event.payload, "resource_event.payload")?,
                    event.invocation_id.as_ref().map(InvocationId::as_str),
                    event.trace_id.as_str(),
                    event.occurred_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("resource.event", err.to_string()))?;
        Ok(())
    }
}

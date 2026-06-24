use std::collections::BTreeMap;

use chrono::Utc;
use serde_json::{Value, json};

use super::super::definitions::type_definition_from_request;
use super::super::types::*;
use super::super::validation::{
    ensure_lifecycle, ensure_relation, validate_create_request, validate_link_request,
    validate_list_filter, validate_resource_payload, validate_token, validate_type_request,
    validate_update_request,
};
use super::super::versions::payload_hash;
use super::generated_id;
use super::resource_event;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{InvocationId, TraceId};

/// In-memory resource store.
#[derive(Default)]
pub struct InMemoryEngineResourceStore {
    type_definitions: BTreeMap<String, EngineResourceTypeDefinition>,
    resources: BTreeMap<String, EngineResource>,
    versions: BTreeMap<String, EngineResourceVersion>,
    versions_by_resource: BTreeMap<String, Vec<String>>,
    links: BTreeMap<String, EngineResourceLink>,
    events_by_resource: BTreeMap<String, Vec<EngineResourceEvent>>,
}

impl InMemoryEngineResourceStore {
    /// Create an empty resource store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Register or update one resource type definition.
    pub fn register_type(
        &mut self,
        request: RegisterResourceType,
    ) -> Result<EngineResourceTypeDefinition> {
        validate_type_request(&request)?;
        let now = Utc::now();
        let revision = self
            .type_definitions
            .get(&request.kind)
            .map_or(1, |definition| definition.revision.saturating_add(1));
        let created_at = self
            .type_definitions
            .get(&request.kind)
            .map_or(now, |definition| definition.created_at);
        let definition = type_definition_from_request(request, revision, created_at, now);
        self.type_definitions
            .insert(definition.kind.clone(), definition.clone());
        Ok(definition)
    }

    /// Read one resource type definition.
    pub fn get_type(&self, kind: &str) -> Result<Option<EngineResourceTypeDefinition>> {
        validate_token("resource kind", kind)?;
        Ok(self.type_definitions.get(kind).cloned())
    }

    /// List registered resource type definitions.
    pub fn list_types(&self) -> Result<Vec<EngineResourceTypeDefinition>> {
        Ok(self.type_definitions.values().cloned().collect())
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
        if let Some(payload) = &request.initial_payload {
            validate_resource_payload(&type_definition, payload)?;
        }
        let now = Utc::now();
        let resource_id = request
            .resource_id
            .clone()
            .unwrap_or_else(|| generated_id("res"));
        if self.resources.contains_key(&resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "resource {resource_id} already exists"
            )));
        }
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
        self.resources.insert(resource_id.clone(), resource.clone());
        self.record_event(resource_event(
            &resource_id,
            "resource.created",
            json!({"kind": resource.kind, "lifecycle": resource.lifecycle}),
            request.invocation_id.clone(),
            request.trace_id.clone(),
        ));
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
            self.resources.insert(resource_id, resource.clone());
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
        self.links.insert(link.link_id.clone(), link.clone());
        self.record_event(resource_event(
            &link.source_resource_id,
            "resource.linked",
            json!({
                "targetResourceId": link.target_resource_id,
                "relation": link.relation,
            }),
            request.invocation_id,
            request.trace_id,
        ));
        Ok(link)
    }

    /// Inspect one resource.
    pub fn inspect(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>> {
        validate_token("resource id", resource_id)?;
        let Some(resource) = self.resources.get(resource_id).cloned() else {
            return Ok(None);
        };
        Ok(Some(EngineResourceInspection {
            versions: self
                .versions_by_resource
                .get(resource_id)
                .into_iter()
                .flatten()
                .filter_map(|version_id| self.versions.get(version_id))
                .cloned()
                .collect(),
            outgoing_links: self
                .links
                .values()
                .filter(|link| link.source_resource_id == resource_id)
                .cloned()
                .collect(),
            incoming_links: self
                .links
                .values()
                .filter(|link| link.target_resource_id == resource_id)
                .cloned()
                .collect(),
            events: self
                .events_by_resource
                .get(resource_id)
                .cloned()
                .unwrap_or_default(),
            resource,
        }))
    }

    /// List resources.
    pub fn list(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        validate_list_filter(&filter)?;
        let mut resources = self
            .resources
            .values()
            .filter(|resource| {
                filter
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
            })
            .cloned()
            .collect::<Vec<_>>();
        resources.sort_by_key(|resource| resource.updated_at);
        resources.reverse();
        resources.truncate(filter.limit.min(500));
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
        self.versions
            .insert(version.version_id.clone(), version.clone());
        self.versions_by_resource
            .entry(resource_id.to_owned())
            .or_default()
            .push(version.version_id.clone());
        if version.state.may_be_current() {
            resource.current_version_id = Some(version.version_id.clone());
        }
        if let Some(lifecycle) = lifecycle {
            resource.lifecycle = lifecycle;
        }
        resource.updated_at = Utc::now();
        self.resources.insert(resource_id.to_owned(), resource);
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
        ));
        Ok(version)
    }

    fn require_type(&self, kind: &str) -> Result<EngineResourceTypeDefinition> {
        self.get_type(kind)?.ok_or_else(|| EngineError::NotFound {
            kind: "resource_type",
            id: kind.to_owned(),
        })
    }

    fn require_resource(&self, resource_id: &str) -> Result<EngineResource> {
        self.resources
            .get(resource_id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "resource",
                id: resource_id.to_owned(),
            })
    }

    fn record_event(&mut self, event: EngineResourceEvent) {
        self.events_by_resource
            .entry(event.resource_id.clone())
            .or_default()
            .push(event);
    }
}

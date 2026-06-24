use super::common::{
    create_typed_resource, current_payload, ensure_resource_kind, resource_ref_from_resource,
    resource_ref_from_version,
};
use super::input::resource_scope_from_payload;
use super::*;

pub(super) fn materialized_file_create_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let (resource, version) = create_materialized_file(store, invocation, false)?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "materialized");
    Ok(json!({
        "version": version,
        "resource": resource,
        "resourceRefs": [resource_ref],
    }))
}

pub(super) fn materialized_file_update_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let (resource, version) = create_materialized_file(store, invocation, true)?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "updated");
    Ok(json!({
        "version": version,
        "resource": resource,
        "resourceRefs": [resource_ref],
    }))
}

pub(super) fn create_materialized_file(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    allow_update: bool,
) -> Result<(EngineResource, EngineResourceVersion)> {
    let path = required_str(&invocation.payload, "path")?;
    let content = optional_string(invocation.payload.get("content"))?.unwrap_or_default();
    let canonical = canonical_materialized_path(invocation, path)?;
    let content_hash = sha256_hex(content.as_bytes());
    if let Some(declared) = optional_string(invocation.payload.get("contentHash"))?
        && declared != content_hash
    {
        return Err(EngineError::PolicyViolation(format!(
            "materialized file hash mismatch for {}: declared {declared}, actual {content_hash}",
            canonical.display()
        )));
    }
    let resource_id = optional_string(invocation.payload.get("resourceId"))?
        .unwrap_or_else(|| materialized_file_resource_id(&canonical));
    let existing = store.inspect(&resource_id)?;
    let update_expected = if let Some(inspection) = &existing {
        ensure_resource_kind(&inspection, "materialized_file")?;
        ensure_materialized_file_operational(&inspection, "updated")?;
        if !allow_update {
            return Err(EngineError::PolicyViolation(format!(
                "materialized file resource {resource_id} already exists"
            )));
        }
        let caller_expected = optional_string(invocation.payload.get("expectedCurrentVersionId"))?;
        if caller_expected.is_some()
            && caller_expected.as_ref() != inspection.resource.current_version_id.as_ref()
        {
            return Err(EngineError::PolicyViolation(format!(
                "resource {resource_id} version conflict: expected {:?}, actual {:?}",
                caller_expected, inspection.resource.current_version_id
            )));
        }
        Some(caller_expected.or(inspection.resource.current_version_id.clone()))
    } else {
        None
    };
    let new_scope = if existing.is_none() {
        Some(resource_scope_from_payload(invocation, false)?)
    } else {
        None
    };
    materialize_content_at_path(&canonical, &content)?;
    let payload = materialized_file_payload(&canonical, &content, &content_hash)?;
    let locations = materialized_file_locations(&canonical, content.len() as u64, &content_hash);
    if existing.is_some() {
        let version = store.update(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: update_expected.flatten(),
            lifecycle: Some("materialized".to_owned()),
            payload,
            state: None,
            locations,
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let resource = store.inspect(&resource_id)?.unwrap().resource;
        Ok((resource, version))
    } else {
        let resource = store.create(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: "materialized_file".to_owned(),
            schema_id: None,
            scope: new_scope.expect("new materialized file scope is resolved before write"),
            owner_worker_id: WorkerId::new(RESOURCE_WORKER_ID).unwrap(),
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("materialized".to_owned()),
            policy: invocation
                .payload
                .get("policy")
                .cloned()
                .unwrap_or_else(|| json!({})),
            initial_payload: Some(payload),
            locations,
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })?;
        let version = current_version_for_resource(store, &resource.resource_id)?;
        Ok((resource, version))
    }
}

pub(super) fn artifact_materialize_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let artifact_id = required_string_owned(&invocation.payload, "artifactResourceId")?;
    let path = required_str(&invocation.payload, "path")?;
    let inspection = store
        .inspect(&artifact_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: artifact_id.clone(),
        })?;
    ensure_resource_kind(&inspection, "artifact")?;
    let artifact_payload = current_payload(&inspection)?;
    let content = artifact_payload
        .get("body")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| artifact_payload.to_string());
    let payload = json!({
        "path": path,
        "content": content,
        "resourceId": optional_string(invocation.payload.get("resourceId"))?,
    });
    let mut child_invocation = invocation.clone();
    child_invocation.payload = payload;
    let (materialized, version) = create_materialized_file(store, &child_invocation, true)?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "materialized");
    Ok(json!({
        "artifact": inspection.resource,
        "materializedFile": materialized,
        "version": version,
        "resourceRefs": [resource_ref],
    }))
}

pub(super) fn materialized_file_read_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let resource_id = required_str(&invocation.payload, "resourceId")?;
    let inspection = store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    ensure_resource_kind(&inspection, "materialized_file")?;
    ensure_materialized_file_operational(&inspection, "read")?;
    let payload = current_payload(&inspection)?;
    let content = payload
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    Ok(json!({"content": content, "resource": inspection.resource}))
}

pub(super) fn materialized_file_hash_verify_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let resource_id = required_string_owned(&invocation.payload, "resourceId")?;
    let inspection = store
        .inspect(&resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.clone(),
        })?;
    ensure_resource_kind(&inspection, "materialized_file")?;
    ensure_materialized_file_operational(&inspection, "verified")?;
    let current = current_version_for_inspection(&inspection)?;
    let payload = current.payload.clone();
    let canonical = payload
        .get("canonicalPath")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation("materialized file has no canonicalPath".to_owned())
        })?;
    let bytes = match std::fs::read(canonical) {
        Ok(bytes) => bytes,
        Err(error) => {
            return damaged_materialized_file_response(
                store,
                invocation,
                &inspection,
                &current,
                &payload,
                format!("materialized file bytes are missing or unreadable: {error}"),
                None,
            );
        }
    };
    let actual_hash = sha256_hex(&bytes);
    let expected_hash = payload
        .get("contentHash")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if actual_hash == expected_hash {
        let resource_ref = resource_ref_from_version(&current, "materialized_file", "verified");
        return Ok(json!({
            "version": current,
            "resourceRefs": [resource_ref],
        }));
    }
    damaged_materialized_file_response(
        store,
        invocation,
        &inspection,
        &current,
        &payload,
        "file bytes do not match contentHash",
        Some(actual_hash),
    )
}

pub(super) fn ensure_materialized_file_operational(
    inspection: &EngineResourceInspection,
    operation: &str,
) -> Result<()> {
    if inspection.resource.lifecycle == "discarded" {
        return Err(EngineError::PolicyViolation(format!(
            "materialized file resource {} is discarded and cannot be {operation}",
            inspection.resource.resource_id
        )));
    }
    Ok(())
}

pub(super) fn damaged_materialized_file_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
    inspection: &EngineResourceInspection,
    current: &EngineResourceVersion,
    payload: &Value,
    damage_reason: impl Into<String>,
    actual_hash: Option<String>,
) -> Result<Value> {
    let mut damaged_payload = payload.clone();
    damaged_payload["actualContentHash"] = actual_hash.map_or(Value::Null, Value::String);
    damaged_payload["damageReason"] = json!(damage_reason.into());
    let version = store.update(UpdateResource {
        resource_id: inspection.resource.resource_id.clone(),
        expected_current_version_id: inspection.resource.current_version_id.clone(),
        lifecycle: Some("damaged".to_owned()),
        payload: damaged_payload,
        state: Some(crate::engine::durability::resources::EngineResourceVersionState::Damaged),
        locations: current.locations.clone(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    let resource_ref = resource_ref_from_version(&version, "materialized_file", "damaged");
    Ok(json!({
        "version": version,
        "resourceRefs": [resource_ref],
    }))
}

pub(super) fn patch_propose_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let mut payload = serde_json::Map::new();
    payload.insert(
        "targetPath".to_owned(),
        json!(required_str(&invocation.payload, "targetPath")?),
    );
    for field in ["targetResourceId", "baseVersionId", "baseContentHash"] {
        if let Some(value) = optional_string(invocation.payload.get(field))? {
            payload.insert(field.to_owned(), json!(value));
        }
    }
    payload.insert(
        "diff".to_owned(),
        json!(required_str(&invocation.payload, "diff")?),
    );
    payload.insert("status".to_owned(), json!("proposed"));
    payload.insert(
        "result".to_owned(),
        invocation
            .payload
            .get("result")
            .cloned()
            .unwrap_or_else(|| json!({})),
    );
    let resource = create_typed_resource(
        store,
        invocation,
        "patch_proposal",
        Some("proposed"),
        Some(Value::Object(payload)),
    )?;
    let resource_ref = resource_ref_from_resource(&resource, "patch");
    Ok(json!({
        "resource": resource,
        "resourceRefs": [resource_ref],
    }))
}

pub(super) fn patch_apply_response(
    store: &mut super::ResourceStoreBackend,
    invocation: &Invocation,
) -> Result<Value> {
    let patch_id = required_string_owned(&invocation.payload, "patchResourceId")?;
    let patch_inspection = store
        .inspect(&patch_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: patch_id.clone(),
        })?;
    ensure_resource_kind(&patch_inspection, "patch_proposal")?;
    let patch_payload = current_payload(&patch_inspection)?;
    let path = patch_payload
        .get("targetPath")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation("patch proposal missing targetPath".to_owned())
        })?;
    let new_content = required_str(&invocation.payload, "content")?;
    let mut child_invocation = invocation.clone();
    child_invocation.payload = json!({
        "path": path,
        "content": new_content,
        "resourceId": optional_string(invocation.payload.get("targetResourceId"))?
            .or_else(|| patch_payload.get("targetResourceId").and_then(Value::as_str).map(str::to_owned)),
    });
    let (_materialized, file_version) = create_materialized_file(store, &child_invocation, true)?;
    let mut patch_payload_update = serde_json::Map::new();
    patch_payload_update.insert("targetPath".to_owned(), json!(path));
    patch_payload_update.insert(
        "targetResourceId".to_owned(),
        json!(file_version.resource_id.as_str()),
    );
    for field in ["baseVersionId", "baseContentHash"] {
        if let Some(value) = patch_payload.get(field).and_then(Value::as_str) {
            patch_payload_update.insert(field.to_owned(), json!(value));
        }
    }
    patch_payload_update.insert(
        "diff".to_owned(),
        patch_payload
            .get("diff")
            .cloned()
            .unwrap_or_else(|| json!("")),
    );
    patch_payload_update.insert("status".to_owned(), json!("applied"));
    patch_payload_update.insert(
        "result".to_owned(),
        json!({"versionId": file_version.version_id.as_str()}),
    );
    let patch_version = store.update(UpdateResource {
        resource_id: patch_id.clone(),
        expected_current_version_id: patch_inspection.resource.current_version_id.clone(),
        lifecycle: Some("applied".to_owned()),
        payload: Value::Object(patch_payload_update),
        state: None,
        locations: Vec::new(),
        trace_id: invocation.causal_context.trace_id.clone(),
        invocation_id: Some(invocation.id.clone()),
    })?;
    let patch_ref = resource_ref_from_version(&patch_version, "patch_proposal", "applied_patch");
    let file_ref = resource_ref_from_version(&file_version, "materialized_file", "patched_file");
    Ok(json!({
        "patch": patch_version,
        "version": file_version,
        "resourceRefs": [patch_ref, file_ref],
    }))
}

pub(super) fn current_version_for_resource(
    store: &super::ResourceStoreBackend,
    resource_id: &str,
) -> Result<EngineResourceVersion> {
    let inspection = store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })?;
    current_version_for_inspection(&inspection)
}

pub(super) fn current_version_for_inspection(
    inspection: &EngineResourceInspection,
) -> Result<EngineResourceVersion> {
    let current = inspection
        .resource
        .current_version_id
        .as_ref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current version",
                inspection.resource.resource_id
            ))
        })?;
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .cloned()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} current version {current} is missing",
                inspection.resource.resource_id
            ))
        })
}

pub(super) fn materialized_file_payload(
    canonical: &Path,
    content: &str,
    content_hash: &str,
) -> Result<Value> {
    let metadata = std::fs::metadata(canonical).ok();
    Ok(json!({
        "canonicalPath": canonical.to_string_lossy(),
        "relativePath": canonical.file_name().and_then(|name| name.to_str()).unwrap_or_default(),
        "entryType": if metadata.as_ref().is_some_and(std::fs::Metadata::is_dir) { "directory" } else { "file" },
        "content": content,
        "contentHash": content_hash,
        "sizeBytes": u64::try_from(content.len()).unwrap_or(u64::MAX),
        "mimeType": "text/plain",
        "metadata": {
            "readonly": metadata.map(|metadata| metadata.permissions().readonly()).unwrap_or(false)
        }
    }))
}

pub(super) fn materialized_file_locations(
    canonical: &Path,
    size_bytes: u64,
    content_hash: &str,
) -> Vec<EngineResourceLocation> {
    vec![
        EngineResourceLocation {
            kind: "file".to_owned(),
            uri: canonical.to_string_lossy().into_owned(),
            mime_type: Some("text/plain".to_owned()),
            size_bytes: Some(size_bytes),
        },
        EngineResourceLocation {
            kind: "blob".to_owned(),
            uri: format!("sha256:{content_hash}"),
            mime_type: Some("text/plain".to_owned()),
            size_bytes: Some(size_bytes),
        },
    ]
}

pub(super) fn materialized_file_resource_id(path: &Path) -> String {
    let hash = sha256_hex(path.to_string_lossy().as_bytes());
    format!("materialized_file:{hash}")
}

pub(super) fn canonical_materialized_path(invocation: &Invocation, path: &str) -> Result<PathBuf> {
    let candidate = PathBuf::from(path);
    if candidate.exists() {
        return candidate.canonicalize().map_err(|error| {
            EngineError::PolicyViolation(format!("canonicalize {path}: {error}"))
        });
    }
    let absolute = if candidate.is_absolute() {
        candidate
    } else if let Some(base) = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
    {
        let mut relative = PathBuf::new();
        for component in candidate.components() {
            match component {
                Component::Normal(part) => relative.push(part),
                Component::CurDir => {}
                Component::ParentDir => {
                    return Err(EngineError::PolicyViolation(format!(
                        "relative materialized path {path} must stay inside the active working directory"
                    )));
                }
                Component::RootDir | Component::Prefix(_) => {
                    return Err(EngineError::PolicyViolation(format!(
                        "invalid relative materialized path {path}"
                    )));
                }
            }
        }
        if relative.as_os_str().is_empty() {
            return Err(EngineError::PolicyViolation(
                "materialized path cannot be empty".to_owned(),
            ));
        }
        PathBuf::from(base).join(relative)
    } else {
        std::env::current_dir()
            .map_err(|error| EngineError::HandlerFailed(format!("read current dir: {error}")))?
            .join(candidate)
    };
    let mut suffix = Vec::new();
    let mut ancestor = absolute.as_path();
    while !ancestor.exists() {
        let name = ancestor.file_name().ok_or_else(|| {
            EngineError::PolicyViolation(format!("path {path} has no materializable name"))
        })?;
        suffix.push(name.to_os_string());
        ancestor = ancestor.parent().ok_or_else(|| {
            EngineError::PolicyViolation(format!("path {path} has no materializable parent"))
        })?;
    }
    let mut resolved = ancestor
        .canonicalize()
        .map_err(|error| EngineError::PolicyViolation(format!("canonicalize parent: {error}")))?;
    for component in suffix.iter().rev() {
        resolved.push(component);
    }
    Ok(resolved)
}

pub(super) fn materialize_content_at_path(canonical: &Path, content: &str) -> Result<()> {
    if canonical.exists() && canonical.is_dir() {
        if content.is_empty() {
            return Ok(());
        }
        return Err(EngineError::PolicyViolation(format!(
            "cannot materialize file bytes over directory {}",
            canonical.display()
        )));
    }
    if let Some(parent) = canonical.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            EngineError::HandlerFailed(format!("create materialized file parent: {error}"))
        })?;
    }
    std::fs::write(canonical, content.as_bytes())
        .map_err(|error| EngineError::HandlerFailed(format!("write materialized file: {error}")))
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

//! Native UI definition lifecycle, surface projection, streaming, and action routing.

use std::collections::BTreeSet;

use serde_json::{Value, json};
use uuid::Uuid;

use super::catalog::{
    CATALOG_ID, CATALOG_REVISION, MAX_CLIENT_FUNCTIONS, client_function_contract,
    supports_client_function,
};
use super::model::{
    ClientCatalog, NativeUIDefinition, SurfaceLifecycle, SurfaceSnapshot, ValidationDiagnostic,
    ValidationReport,
};
use super::store::StoreError;
use super::{Deps, builtins, providers, validation};
use crate::engine::{
    ActorContext, DeliveryMode, FunctionId, Invocation, PublishStreamEvent, VisibilityScope,
};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

pub(crate) async fn validate_definition(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let value = required_value(&invocation.payload, "definition")?;
    let (definition, report) = validate_value(value, invocation, deps).await?;
    Ok(json!({
        "definitionId": definition.definition_id,
        "report": report,
    }))
}

pub(crate) async fn create_preview(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let value = required_value(&invocation.payload, "definition")?;
    let (definition, report) = validate_value(value, invocation, deps).await?;
    ensure_valid(&report)?;
    let store = deps.store.clone();
    let definition_for_store = definition.clone();
    let hash = report.content_hash.clone();
    let diagnostics = report.diagnostics.clone();
    let revision = run_blocking_task("native_ui.create_preview", move || {
        store
            .save_preview(&definition_for_store, &hash, &diagnostics)
            .map_err(store_error)
    })
    .await?;
    let mut snapshot = snapshot_from_definition(
        definition,
        revision.revision,
        "preview",
        report.diagnostics,
        invocation,
        deps,
    )?;
    snapshot.surface_id = format!("preview:{}", Uuid::now_v7());
    Ok(json!({"revision": revision, "surface": snapshot}))
}

pub(crate) async fn activate_definition(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    if !invocation
        .payload
        .as_object()
        .is_some_and(|object| object.contains_key("expectedActiveRevision"))
    {
        return Err(CapabilityError::InvalidParams {
            message: "expectedActiveRevision is required (use null for first activation)"
                .to_owned(),
        });
    }
    let expected = optional_u64(&invocation.payload, "expectedActiveRevision")?;
    let value = required_value(&invocation.payload, "definition")?;
    let (definition, report) = validate_value(value, invocation, deps).await?;
    ensure_valid(&report)?;
    let store = deps.store.clone();
    let definition_for_store = definition.clone();
    let hash = report.content_hash.clone();
    let diagnostics = report.diagnostics.clone();
    let revision = run_blocking_task("native_ui.activate_definition", move || {
        store
            .activate(&definition_for_store, &hash, &diagnostics, expected)
            .map_err(store_error)
    })
    .await?;
    let snapshot = snapshot_from_definition(
        definition,
        revision.revision,
        "active",
        report.diagnostics,
        invocation,
        deps,
    )?;
    publish_snapshot(deps, invocation, &snapshot).await?;
    Ok(json!({"revision": revision, "surface": snapshot}))
}

pub(crate) async fn list_revisions(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let definition_id = required_string(&invocation.payload, "definitionId")?.to_owned();
    let limit = optional_u64(&invocation.payload, "limit")?.unwrap_or(50) as usize;
    let store = deps.store.clone();
    let revisions = run_blocking_task("native_ui.list_revisions", move || {
        store.history(&definition_id, limit).map_err(store_error)
    })
    .await?;
    Ok(json!({"revisions": revisions}))
}

pub(crate) async fn rollback_definition(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let definition_id = required_string(&invocation.payload, "definitionId")?.to_owned();
    let target = required_u64(&invocation.payload, "targetRevision")?;
    if !invocation
        .payload
        .as_object()
        .is_some_and(|object| object.contains_key("expectedActiveRevision"))
    {
        return Err(CapabilityError::InvalidParams {
            message: "expectedActiveRevision is required".to_owned(),
        });
    }
    let expected = optional_u64(&invocation.payload, "expectedActiveRevision")?;
    // Validate the immutable target before changing the active pointer. A
    // capability or catalog revision may have become incompatible since this
    // definition was originally accepted.
    let store = deps.store.clone();
    let id_for_lookup = definition_id.clone();
    let target_revision = run_blocking_task("native_ui.read_rollback_target", move || {
        store
            .revision(&id_for_lookup, target)
            .map_err(store_error)?
            .ok_or_else(|| store_error(StoreError::RevisionNotFound(id_for_lookup, target)))
    })
    .await?;
    let report = validate_current_contracts(&target_revision.definition, invocation, deps).await;
    let diagnostics = report.diagnostics;
    if !diagnostics.is_empty() {
        return Err(CapabilityError::Custom {
            code: "NATIVE_UI_ROLLBACK_INVALID".to_owned(),
            message: format!(
                "Revision {target} of {definition_id} is no longer compatible with the live catalog"
            ),
            details: Some(json!({"diagnostics": diagnostics})),
        });
    }
    let store = deps.store.clone();
    let id_for_store = definition_id.clone();
    let revision = run_blocking_task("native_ui.rollback_definition", move || {
        store
            .rollback(&id_for_store, target, expected)
            .map_err(store_error)
    })
    .await?;
    let snapshot = snapshot_from_definition(
        revision.definition.clone(),
        revision.revision,
        "rollback",
        Vec::new(),
        invocation,
        deps,
    )?;
    publish_snapshot(deps, invocation, &snapshot).await?;
    Ok(json!({"revision": revision, "surface": snapshot}))
}

pub(crate) async fn get_surface(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let _publication = deps.surface_publication.lock().await;
    let mut snapshot = build_surface(invocation, deps).await?;
    stamp_surface_sequence(&mut snapshot, deps)?;
    Ok(serde_json::to_value(snapshot).map_err(serialization_error)?)
}

pub(crate) async fn reconstruct_surface(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let _publication = deps.surface_publication.lock().await;
    if let Some(surface_id) = optional_string(&invocation.payload, "surfaceId")? {
        let store = deps.store.clone();
        let lookup = surface_id.to_owned();
        if let Some((state, snapshot)) =
            run_blocking_task("native_ui.reconstruct_transient", move || {
                store.transient(&lookup).map_err(store_error)
            })
            .await?
        {
            if state == "active" {
                validate_transient_source(&snapshot, deps).await?;
                let mut snapshot = snapshot;
                stamp_surface_sequence(&mut snapshot, deps)?;
                return serde_json::to_value(snapshot).map_err(serialization_error);
            }
            return Err(CapabilityError::Custom {
                code: "NATIVE_UI_SURFACE_DISMISSED".to_owned(),
                message: format!("Surface {surface_id} is {state}"),
                details: Some(json!({"surfaceId": surface_id, "state": state})),
            });
        }
    }
    let mut snapshot = build_surface(invocation, deps).await?;
    stamp_surface_sequence(&mut snapshot, deps)?;
    Ok(serde_json::to_value(snapshot).map_err(serialization_error)?)
}

pub(crate) async fn dismiss_surface(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let surface_id = required_string(&invocation.payload, "surfaceId")?.to_owned();
    let store = deps.store.clone();
    let lookup = surface_id.clone();
    let dismissed_snapshot = run_blocking_task("native_ui.dismiss_surface", move || {
        store.dismiss_transient(&lookup).map_err(store_error)
    })
    .await?;
    if let Some(snapshot) = &dismissed_snapshot {
        publish_delete(deps, invocation, snapshot).await?;
    }
    Ok(json!({"surfaceId": surface_id, "dismissed": dismissed_snapshot.is_some()}))
}

pub(crate) async fn register_client_catalog(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let catalog: ClientCatalog = serde_json::from_value(
        required_value(&invocation.payload, "catalog")?.clone(),
    )
    .map_err(|error| CapabilityError::InvalidParams {
        message: format!("Invalid client catalog: {error}"),
    })?;
    if catalog.client_id.trim().is_empty()
        || catalog.catalog_id != CATALOG_ID
        || catalog.catalog_revision != CATALOG_REVISION
        || catalog.functions.len() > MAX_CLIENT_FUNCTIONS
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Client catalog must identify a client and advertise {CATALOG_ID} revision {CATALOG_REVISION} with at most {MAX_CLIENT_FUNCTIONS} functions"
            ),
        });
    }
    let mut names = BTreeSet::new();
    for function in &catalog.functions {
        if !names.insert((function.name.as_str(), function.revision)) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Duplicate client function {} revision {}",
                    function.name, function.revision
                ),
            });
        }
        if !supports_client_function(&function.name, function.revision) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Server catalog does not recognize client function {} revision {}",
                    function.name, function.revision
                ),
            });
        }
        if !function.parameters.is_object() {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Client function {} parameters must be a JSON Schema object",
                    function.name
                ),
            });
        }
        let Some((parameters, return_type)) =
            client_function_contract(&function.name, function.revision)
        else {
            unreachable!("supports_client_function and contract lookup must agree")
        };
        if function.parameters != parameters || function.return_type != return_type {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Client function {} revision {} does not match the server parameter or return schema",
                    function.name, function.revision
                ),
            });
        }
    }
    deps.client_catalogs
        .write()
        .map_err(|_| CapabilityError::Internal {
            message: "Client catalog registry lock is poisoned".to_owned(),
        })?
        .insert(catalog.client_id.clone(), catalog.clone());
    Ok(json!({
        "accepted": true,
        "clientId": catalog.client_id,
        "catalogId": CATALOG_ID,
        "catalogRevision": CATALOG_REVISION,
        "functionCount": catalog.functions.len(),
    }))
}

pub(crate) async fn dispatch_action(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let definition_id = required_string(&invocation.payload, "definitionId")?.to_owned();
    let function_id = required_string(&invocation.payload, "functionId")?.to_owned();
    let arguments = required_value(&invocation.payload, "arguments")?.clone();
    if !arguments.is_object() {
        return Err(CapabilityError::InvalidParams {
            message: "arguments must be an object".to_owned(),
        });
    }
    let idempotency_key = required_string(&invocation.payload, "idempotencyKey")?.to_owned();
    let (definition, _, _, _) = resolve_definition(&definition_id, invocation, deps).await?;
    if !definition_binds_capability(&definition, &function_id) {
        return Err(CapabilityError::Custom {
            code: "NATIVE_UI_ACTION_NOT_BOUND".to_owned(),
            message: format!("Definition {definition_id} does not bind capability {function_id}"),
            details: None,
        });
    }
    let target =
        FunctionId::new(function_id.clone()).map_err(|error| CapabilityError::InvalidParams {
            message: error.to_string(),
        })?;
    let mut context = invocation.causal_context.clone();
    context.parent_invocation_id = Some(invocation.id.clone());
    context.idempotency_key = Some(idempotency_key);
    context.delivery_mode = DeliveryMode::Sync;
    let child = Invocation::new_sync(target, arguments, context);
    let result = deps.engine_host.invoke(child).await;
    let value = crate::shared::server::error_mapping::result_to_capability_value(result)?;

    if definition_id == "settings.engine" {
        let snapshot =
            build_persistent_surface("settings.engine", "settings.engine", invocation, deps)
                .await?;
        publish_snapshot(deps, invocation, &snapshot).await?;
    }
    Ok(json!({"functionId": function_id, "result": value}))
}

async fn build_surface(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<SurfaceSnapshot, CapabilityError> {
    let definition_id = required_string(&invocation.payload, "definitionId")?;
    match definition_id {
        "session.compaction_detail" => {
            let session_id = required_string(&invocation.payload, "sessionId")?;
            let event_id = required_string(&invocation.payload, "eventId")?;
            let surface_id = optional_string(&invocation.payload, "surfaceId")?
                .map(str::to_owned)
                .unwrap_or_else(|| format!("session.compaction_detail:{session_id}:{event_id}"));
            build_compaction_surface(&surface_id, session_id, event_id, invocation, deps).await
        }
        "settings.engine" | "lab.catalog" => {
            let surface_id =
                optional_string(&invocation.payload, "surfaceId")?.unwrap_or(definition_id);
            build_persistent_surface(definition_id, surface_id, invocation, deps).await
        }
        other => Err(CapabilityError::NotFound {
            code: "NATIVE_UI_DEFINITION_NOT_FOUND".to_owned(),
            message: format!("Native UI definition {other} was not found"),
        }),
    }
}

async fn build_persistent_surface(
    definition_id: &str,
    surface_id: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<SurfaceSnapshot, CapabilityError> {
    let (definition, revision, source, diagnostics) =
        resolve_definition(definition_id, invocation, deps).await?;
    validate_client_support(invocation, deps, &definition.messages)?;
    let mut snapshot =
        snapshot_from_definition(definition, revision, &source, diagnostics, invocation, deps)?;
    snapshot.surface_id = surface_id.to_owned();
    Ok(snapshot)
}

async fn build_compaction_surface(
    surface_id: &str,
    session_id: &str,
    event_id: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<SurfaceSnapshot, CapabilityError> {
    let store = deps.store.clone();
    let lookup = surface_id.to_owned();
    if let Some((state, snapshot)) = run_blocking_task("native_ui.load_transient", move || {
        store.transient(&lookup).map_err(store_error)
    })
    .await?
    {
        if state == "active" {
            validate_transient_source(&snapshot, deps).await?;
            validate_client_support(invocation, deps, &snapshot.messages)?;
            return Ok(snapshot);
        }
        return Err(CapabilityError::Custom {
            code: "NATIVE_UI_SURFACE_DISMISSED".to_owned(),
            message: format!("Surface {surface_id} is {state}"),
            details: Some(json!({"surfaceId": surface_id, "state": state})),
        });
    }
    let (definition, revision, source, diagnostics) =
        resolve_definition("session.compaction_detail", invocation, deps).await?;
    validate_client_support(invocation, deps, &definition.messages)?;
    let mut snapshot =
        snapshot_from_definition(definition, revision, &source, diagnostics, invocation, deps)?;
    snapshot.surface_id = surface_id.to_owned();
    snapshot.session_id = Some(session_id.to_owned());
    snapshot.event_id = Some(event_id.to_owned());
    let logical_surface_id = logical_surface_id(&snapshot.messages)?;
    let data = providers::compaction_data(deps, session_id, event_id)?;
    snapshot
        .messages
        .push(data_message(&logical_surface_id, data));
    let store = deps.store.clone();
    let snapshot_to_store = snapshot.clone();
    let session = session_id.to_owned();
    let event = event_id.to_owned();
    run_blocking_task("native_ui.save_transient", move || {
        store
            .save_transient(&snapshot_to_store, &session, &event)
            .map_err(store_error)
    })
    .await?;
    Ok(snapshot)
}

async fn validate_transient_source(
    snapshot: &SurfaceSnapshot,
    deps: &Deps,
) -> Result<(), CapabilityError> {
    if snapshot.definition_id != "session.compaction_detail" {
        return Ok(());
    }
    let session_id = snapshot
        .session_id
        .as_deref()
        .ok_or_else(|| CapabilityError::Internal {
            message: format!(
                "Transient surface {} is missing session identity",
                snapshot.surface_id
            ),
        })?;
    let event_id = snapshot
        .event_id
        .as_deref()
        .ok_or_else(|| CapabilityError::Internal {
            message: format!(
                "Transient surface {} is missing event identity",
                snapshot.surface_id
            ),
        })?;
    if let Err(error) = providers::compaction_data(deps, session_id, event_id) {
        let store = deps.store.clone();
        let surface_id = snapshot.surface_id.clone();
        run_blocking_task("native_ui.expire_transient", move || {
            store.expire_transient(&surface_id).map_err(store_error)
        })
        .await?;
        return Err(error);
    }
    Ok(())
}

fn snapshot_from_definition(
    definition: NativeUIDefinition,
    revision: u64,
    source: &str,
    diagnostics: Vec<ValidationDiagnostic>,
    _invocation: &Invocation,
    deps: &Deps,
) -> Result<SurfaceSnapshot, CapabilityError> {
    let logical_surface_id = logical_surface_id(&definition.messages)?;
    let mut messages = definition.messages.clone();
    match definition.definition_id.as_str() {
        "settings.engine" => {
            messages.push(data_message(
                &logical_surface_id,
                providers::settings_data(deps),
            ));
        }
        "lab.catalog" => {
            messages.push(data_message(&logical_surface_id, providers::lab_data()));
        }
        _ => {}
    }
    Ok(SurfaceSnapshot {
        surface_id: definition.definition_id.clone(),
        definition_id: definition.definition_id,
        definition_revision: revision,
        surface_sequence: 0,
        catalog_id: definition.catalog_id,
        catalog_revision: definition.catalog_revision,
        lifecycle: definition.lifecycle,
        source: source.to_owned(),
        presentation: definition.presentation,
        messages,
        diagnostics,
        session_id: None,
        event_id: None,
    })
}

async fn resolve_definition(
    definition_id: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<(NativeUIDefinition, u64, String, Vec<ValidationDiagnostic>), CapabilityError> {
    let store = deps.store.clone();
    let id = definition_id.to_owned();
    let active = run_blocking_task("native_ui.resolve_active", move || {
        store.active_revision(&id).map_err(store_error)
    })
    .await?;
    if let Some(active) = active {
        let report = validate_current_contracts(&active.definition, invocation, deps).await;
        if report.valid {
            return Ok((
                active.definition,
                active.revision,
                "active".to_owned(),
                Vec::new(),
            ));
        }
        let mut fallback_diagnostics = vec![ValidationDiagnostic::new(
            "definition.active_fallback",
            "/",
            format!(
                "Active revision {} failed current validation; bundled definition is in use",
                active.revision
            ),
        )];
        fallback_diagnostics.extend(report.diagnostics);
        let bundled =
            builtins::definition(definition_id).ok_or_else(|| CapabilityError::NotFound {
                code: "NATIVE_UI_DEFINITION_NOT_FOUND".to_owned(),
                message: format!(
                    "Definition {definition_id} has no valid active or bundled revision"
                ),
            })?;
        let bundled_report = validate_current_contracts(&bundled, invocation, deps).await;
        ensure_bundled_compatible(definition_id, &bundled_report)?;
        return Ok((
            bundled,
            0,
            "bundledFallback".to_owned(),
            fallback_diagnostics,
        ));
    }
    let bundled = builtins::definition(definition_id).ok_or_else(|| CapabilityError::NotFound {
        code: "NATIVE_UI_DEFINITION_NOT_FOUND".to_owned(),
        message: format!("Native UI definition {definition_id} was not found"),
    })?;
    let bundled_report = validate_current_contracts(&bundled, invocation, deps).await;
    ensure_bundled_compatible(definition_id, &bundled_report)?;
    Ok((bundled, 0, "bundled".to_owned(), Vec::new()))
}

async fn validate_value(
    value: &Value,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<(NativeUIDefinition, ValidationReport), CapabilityError> {
    let definition = validation::parse_definition(value).map_err(|diagnostic| {
        CapabilityError::InvalidParams {
            message: diagnostic.message,
        }
    })?;
    let report = validate_current_contracts(&definition, invocation, deps).await;
    Ok((definition, report))
}

async fn validate_current_contracts(
    definition: &NativeUIDefinition,
    invocation: &Invocation,
    deps: &Deps,
) -> ValidationReport {
    let mut report = validation::validate_structure(definition);
    let actor = actor_context(invocation);
    report.diagnostics.extend(
        validation::validate_capability_bindings(definition, &deps.engine_host, &actor).await,
    );
    report.valid = report.diagnostics.is_empty();
    report
}

fn ensure_bundled_compatible(
    definition_id: &str,
    report: &ValidationReport,
) -> Result<(), CapabilityError> {
    if report.valid {
        return Ok(());
    }
    Err(CapabilityError::Custom {
        code: "NATIVE_UI_BUNDLED_INCOMPATIBLE".to_owned(),
        message: format!(
            "Bundled native UI definition {definition_id} is incompatible with the live catalog"
        ),
        details: Some(json!({"diagnostics": report.diagnostics})),
    })
}

fn actor_context(invocation: &Invocation) -> ActorContext {
    ActorContext {
        actor_id: invocation.causal_context.actor_id.clone(),
        actor_kind: invocation.causal_context.actor_kind.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        authority_scopes: invocation.causal_context.authority_scopes.clone(),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
    }
}

fn ensure_valid(report: &ValidationReport) -> Result<(), CapabilityError> {
    if report.valid {
        return Ok(());
    }
    Err(CapabilityError::Custom {
        code: "NATIVE_UI_DEFINITION_INVALID".to_owned(),
        message: "Native UI definition failed validation".to_owned(),
        details: Some(json!({"diagnostics": report.diagnostics})),
    })
}

async fn publish_snapshot(
    deps: &Deps,
    invocation: &Invocation,
    snapshot: &SurfaceSnapshot,
) -> Result<(), CapabilityError> {
    let _publication = deps.surface_publication.lock().await;
    let batch_id = Uuid::now_v7().to_string();
    let batch_count = snapshot.messages.len();
    let first_sequence = reserve_surface_sequences(deps, &snapshot.surface_id, batch_count)?;
    for (index, message) in snapshot.messages.iter().enumerate() {
        deps.engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: super::contract::SURFACE_STREAM_TOPIC.to_owned(),
                payload: json!({
                    "surfaceId": snapshot.surface_id,
                    "definitionId": snapshot.definition_id,
                    "definitionRevision": snapshot.definition_revision,
                    "catalogId": snapshot.catalog_id,
                    "catalogRevision": snapshot.catalog_revision,
                    "lifecycle": snapshot.lifecycle,
                    "sequence": first_sequence + index as u64,
                    "batchId": batch_id,
                    "batchIndex": index,
                    "batchCount": batch_count,
                    "isFinal": index + 1 == batch_count,
                    "message": message,
                }),
                visibility: if snapshot.lifecycle == SurfaceLifecycle::Transient {
                    VisibilityScope::Session
                } else {
                    VisibilityScope::System
                },
                session_id: snapshot.session_id.clone(),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                producer: super::contract::WORKER.to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
    }
    Ok(())
}

async fn publish_delete(
    deps: &Deps,
    invocation: &Invocation,
    snapshot: &SurfaceSnapshot,
) -> Result<(), CapabilityError> {
    let _publication = deps.surface_publication.lock().await;
    let logical_surface_id = logical_surface_id(&snapshot.messages)?;
    let sequence = reserve_surface_sequences(deps, &snapshot.surface_id, 1)?;
    deps.engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: super::contract::SURFACE_STREAM_TOPIC.to_owned(),
            payload: json!({
                "surfaceId": snapshot.surface_id,
                "definitionId": snapshot.definition_id,
                "definitionRevision": snapshot.definition_revision,
                "catalogId": snapshot.catalog_id,
                "catalogRevision": snapshot.catalog_revision,
                "lifecycle": snapshot.lifecycle,
                "sequence": sequence,
                "batchId": Uuid::now_v7().to_string(),
                "batchIndex": 0,
                "batchCount": 1,
                "isFinal": true,
                "message": {"version":"v0.9.1","deleteSurface":{"surfaceId":logical_surface_id}},
            }),
            visibility: VisibilityScope::Session,
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: super::contract::WORKER.to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    Ok(())
}

fn reserve_surface_sequences(
    deps: &Deps,
    surface_id: &str,
    count: usize,
) -> Result<u64, CapabilityError> {
    let count = u64::try_from(count).map_err(|_| CapabilityError::Internal {
        message: "Native UI batch count does not fit in the stream sequence".to_owned(),
    })?;
    let mut sequences = deps
        .surface_sequences
        .write()
        .map_err(|_| CapabilityError::Internal {
            message: "Native UI surface sequence registry lock is poisoned".to_owned(),
        })?;
    let current = sequences.get(surface_id).copied().unwrap_or(0);
    let first = current
        .checked_add(1)
        .ok_or_else(|| CapabilityError::Internal {
            message: format!("Native UI surface sequence exhausted for {surface_id}"),
        })?;
    let last = current
        .checked_add(count)
        .ok_or_else(|| CapabilityError::Internal {
            message: format!("Native UI surface sequence exhausted for {surface_id}"),
        })?;
    sequences.insert(surface_id.to_owned(), last);
    Ok(first)
}

fn stamp_surface_sequence(
    snapshot: &mut SurfaceSnapshot,
    deps: &Deps,
) -> Result<(), CapabilityError> {
    snapshot.surface_sequence = deps
        .surface_sequences
        .read()
        .map_err(|_| CapabilityError::Internal {
            message: "Native UI surface sequence registry lock is poisoned".to_owned(),
        })?
        .get(&snapshot.surface_id)
        .copied()
        .unwrap_or(0);
    Ok(())
}

fn validate_client_support(
    invocation: &Invocation,
    deps: &Deps,
    messages: &[Value],
) -> Result<(), CapabilityError> {
    let Some(client_id) = optional_string(&invocation.payload, "clientId")? else {
        return Ok(());
    };
    let catalogs = deps
        .client_catalogs
        .read()
        .map_err(|_| CapabilityError::Internal {
            message: "Client catalog registry lock is poisoned".to_owned(),
        })?;
    let catalog = catalogs
        .get(client_id)
        .ok_or_else(|| CapabilityError::Custom {
            code: "NATIVE_UI_CLIENT_CATALOG_REQUIRED".to_owned(),
            message: format!("Client {client_id} has not advertised its native UI catalog"),
            details: None,
        })?;
    if catalog.catalog_id != CATALOG_ID || catalog.catalog_revision != CATALOG_REVISION {
        return Err(CapabilityError::Custom {
            code: "NATIVE_UI_CLIENT_CATALOG_INCOMPATIBLE".to_owned(),
            message: format!("Client {client_id} does not support the active catalog"),
            details: None,
        });
    }
    let advertised = catalog
        .functions
        .iter()
        .map(|function| (function.name.clone(), function.revision))
        .collect::<BTreeSet<_>>();
    let required = validation::required_client_functions(messages);
    let missing = required
        .difference(&advertised)
        .cloned()
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return Err(CapabilityError::Custom {
            code: "NATIVE_UI_CLIENT_FUNCTION_UNAVAILABLE".to_owned(),
            message: format!(
                "Client {client_id} does not advertise every function required by this surface"
            ),
            details: Some(json!({
                "clientId": client_id,
                "missingFunctions": missing.into_iter().map(|(name, revision)| json!({
                    "name": name,
                    "revision": revision,
                })).collect::<Vec<_>>()
            })),
        });
    }
    Ok(())
}

fn definition_binds_capability(definition: &NativeUIDefinition, target: &str) -> bool {
    definition.messages.iter().any(|message| {
        message
            .get("updateComponents")
            .and_then(|value| value.get("components"))
            .and_then(Value::as_array)
            .is_some_and(|components| {
                components
                    .iter()
                    .any(|component| action_binds(component.get("action"), target))
            })
    })
}

fn action_binds(action: Option<&Value>, target: &str) -> bool {
    let Some(action) = action else { return false };
    action
        .get("serverCapability")
        .and_then(|value| value.get("functionId"))
        .and_then(Value::as_str)
        .is_some_and(|value| value == target)
        || action_binds(action.get("resultAction"), target)
}

fn logical_surface_id(messages: &[Value]) -> Result<String, CapabilityError> {
    messages
        .iter()
        .find_map(|message| {
            message
                .get("createSurface")
                .and_then(|value| value.get("surfaceId"))
                .and_then(Value::as_str)
        })
        .map(str::to_owned)
        .ok_or_else(|| CapabilityError::Internal {
            message: "Validated definition has no createSurface id".to_owned(),
        })
}

fn data_message(surface_id: &str, data: Value) -> Value {
    json!({
        "version": "v0.9.1",
        "updateDataModel": {
            "surfaceId": surface_id,
            "path": "/",
            "value": data,
        }
    })
}

fn required_value<'a>(payload: &'a Value, field: &str) -> Result<&'a Value, CapabilityError> {
    payload
        .get(field)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("Missing required parameter {field}"),
        })
}

fn required_string<'a>(payload: &'a Value, field: &str) -> Result<&'a str, CapabilityError> {
    required_value(payload, field)?
        .as_str()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("Parameter {field} must be a non-empty string"),
        })
}

fn optional_string<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_str()
            .map(Some)
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: format!("Parameter {field} must be a string or null"),
            }),
    }
}

fn required_u64(payload: &Value, field: &str) -> Result<u64, CapabilityError> {
    required_value(payload, field)?
        .as_u64()
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("Parameter {field} must be an unsigned integer"),
        })
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: format!("Parameter {field} must be an unsigned integer or null"),
            }),
    }
}

fn store_error(error: StoreError) -> CapabilityError {
    match error {
        StoreError::RevisionConflict {
            definition_id,
            expected,
            current,
        } => CapabilityError::Custom {
            code: "NATIVE_UI_REVISION_CONFLICT".to_owned(),
            message: format!("Active revision changed for {definition_id}"),
            details: Some(json!({
                "definitionId": definition_id,
                "expectedActiveRevision": expected,
                "currentActiveRevision": current,
            })),
        },
        StoreError::RevisionNotFound(definition_id, revision) => CapabilityError::NotFound {
            code: "NATIVE_UI_REVISION_NOT_FOUND".to_owned(),
            message: format!("Definition {definition_id} has no revision {revision}"),
        },
        other => CapabilityError::Internal {
            message: other.to_string(),
        },
    }
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

fn serialization_error(error: serde_json::Error) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("Failed to encode native UI response: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::native_ui::builtins;

    #[test]
    fn capability_dispatch_requires_a_definition_binding() {
        let definition = builtins::definition("settings.engine").unwrap();
        assert!(definition_binds_capability(&definition, "settings::update"));
        assert!(!definition_binds_capability(&definition, "auth::clear"));
    }
}

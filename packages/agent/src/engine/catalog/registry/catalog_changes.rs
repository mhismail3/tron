//! Catalog change subjects and append-only revision recording.

use chrono::Utc;

use super::LiveCatalog;
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::WorkerId;
use crate::engine::kernel::types::{
    CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogSubjectKind, FunctionDefinition,
    Provenance, TriggerDefinition, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
};

#[derive(Clone)]
pub(super) struct CatalogChangeSubject {
    id: String,
    kind: CatalogSubjectKind,
    visibility: VisibilityScope,
    session_id: Option<String>,
    workspace_id: Option<String>,
    owner_worker: Option<WorkerId>,
}

impl LiveCatalog {
    pub(super) fn record_change(
        &mut self,
        kind: CatalogChangeKind,
        subject: CatalogChangeSubject,
    ) -> Result<()> {
        let before = self.revision;
        let after = self.revision.next();
        let change = CatalogChange {
            id: format!("catalog_change_{}_{}", after.0, uuid::Uuid::now_v7()),
            before,
            after,
            class: catalog_change_class(&kind),
            kind,
            subject_id: subject.id,
            subject_kind: subject.kind,
            visibility: subject.visibility,
            session_id: subject.session_id,
            workspace_id: subject.workspace_id,
            owner_worker: subject.owner_worker,
            timestamp: Utc::now(),
        };
        self.ledger.append_catalog_change(&change)?;
        self.revision = after;
        self.changes.push(change);
        Ok(())
    }
}

pub(super) fn worker_change_subject(definition: &WorkerDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::Worker,
        definition.visibility.clone(),
        &definition.provenance,
        None,
    )
}

pub(super) fn function_change_subject(definition: &FunctionDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::Function,
        definition.visibility.clone(),
        &definition.provenance,
        Some(definition.owner_worker.clone()),
    )
}

pub(super) fn trigger_type_change_subject(
    definition: &TriggerTypeDefinition,
) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::TriggerType,
        definition.visibility.clone(),
        &definition.provenance,
        Some(definition.owner_worker.clone()),
    )
}

pub(super) fn trigger_change_subject(definition: &TriggerDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::Trigger,
        definition.visibility.clone(),
        &definition.provenance,
        Some(definition.owner_worker.clone()),
    )
}

fn provenance_subject(
    id: String,
    kind: CatalogSubjectKind,
    visibility: VisibilityScope,
    provenance: &Provenance,
    owner_worker: Option<WorkerId>,
) -> CatalogChangeSubject {
    CatalogChangeSubject {
        id,
        kind,
        visibility,
        session_id: provenance.session_id.clone(),
        workspace_id: provenance.workspace_id.clone(),
        owner_worker,
    }
}

fn catalog_change_class(kind: &CatalogChangeKind) -> CatalogChangeClass {
    match kind {
        CatalogChangeKind::WorkerRegistered
        | CatalogChangeKind::WorkerUpdated
        | CatalogChangeKind::WorkerUnregistered
        | CatalogChangeKind::FunctionRegistered
        | CatalogChangeKind::FunctionUnregistered => CatalogChangeClass::Availability,
        CatalogChangeKind::FunctionUpdated => CatalogChangeClass::Contract,
        CatalogChangeKind::TriggerTypeRegistered
        | CatalogChangeKind::TriggerTypeUpdated
        | CatalogChangeKind::TriggerTypeUnregistered
        | CatalogChangeKind::TriggerRegistered
        | CatalogChangeKind::TriggerUpdated
        | CatalogChangeKind::TriggerUnregistered => CatalogChangeClass::Trigger,
        CatalogChangeKind::VisibilityChanged => CatalogChangeClass::Visibility,
        CatalogChangeKind::HealthChanged => CatalogChangeClass::Health,
    }
}

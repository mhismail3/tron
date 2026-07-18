//! Native UI protocol and persistence DTOs.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Definition envelope around canonical A2UI v0.9.1 messages.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NativeUIDefinition {
    pub(crate) schema_version: String,
    pub(crate) definition_id: String,
    pub(crate) catalog_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) lifecycle: SurfaceLifecycle,
    pub(crate) presentation: SurfacePresentation,
    pub(crate) messages: Vec<Value>,
}

/// Server-owned lifecycle policy for one surface definition.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SurfaceLifecycle {
    Persistent,
    Transient,
}

impl SurfaceLifecycle {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Persistent => "persistent",
            Self::Transient => "transient",
        }
    }
}

/// Native sheet/navigation metadata kept outside the canonical A2UI messages.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SurfacePresentation {
    pub(crate) title: String,
    pub(crate) detents: Vec<String>,
    pub(crate) shows_dismiss: bool,
}

/// Stable machine-readable validation finding.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ValidationDiagnostic {
    pub(crate) code: String,
    pub(crate) path: String,
    pub(crate) message: String,
}

impl ValidationDiagnostic {
    pub(crate) fn new(
        code: impl Into<String>,
        path: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            path: path.into(),
            message: message.into(),
        }
    }
}

/// Result returned by deterministic definition validation.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ValidationReport {
    pub(crate) valid: bool,
    pub(crate) content_hash: String,
    pub(crate) diagnostics: Vec<ValidationDiagnostic>,
}

/// Durable definition revision projection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DefinitionRevision {
    pub(crate) definition_id: String,
    pub(crate) revision: u64,
    pub(crate) parent_revision: Option<u64>,
    pub(crate) content_hash: String,
    pub(crate) catalog_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) lifecycle: SurfaceLifecycle,
    pub(crate) status: String,
    pub(crate) definition: NativeUIDefinition,
    pub(crate) diagnostics: Vec<ValidationDiagnostic>,
    pub(crate) created_at: String,
}

/// One fully reconstructable surface snapshot.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SurfaceSnapshot {
    pub(crate) surface_id: String,
    pub(crate) definition_id: String,
    pub(crate) definition_revision: u64,
    /// Highest per-surface stream sequence already represented by this
    /// snapshot. Clients use it as the reconstruction barrier.
    #[serde(default)]
    pub(crate) surface_sequence: u64,
    pub(crate) catalog_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) lifecycle: SurfaceLifecycle,
    pub(crate) source: String,
    pub(crate) presentation: SurfacePresentation,
    pub(crate) messages: Vec<Value>,
    pub(crate) diagnostics: Vec<ValidationDiagnostic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) event_id: Option<String>,
}

/// Advertised precompiled native function.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ClientFunctionDescriptor {
    pub(crate) name: String,
    pub(crate) revision: u64,
    pub(crate) parameters: Value,
    pub(crate) return_type: String,
}

/// Versioned native client catalog advertised by an iOS installation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ClientCatalog {
    pub(crate) client_id: String,
    pub(crate) catalog_id: String,
    pub(crate) catalog_revision: u64,
    pub(crate) functions: Vec<ClientFunctionDescriptor>,
}

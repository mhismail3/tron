use serde::Serialize;
use serde_json::Value;

pub(super) const PROVIDER_OUTPUT_SCHEMA_VERSION: &str = "tron.provider_operation_output.v1";
pub(super) const PROVIDER_OUTPUT_MAX_BYTES: usize = 15_000;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderOperationOutput {
    pub(super) schema_version: &'static str,
    pub(super) operation: String,
    pub(super) profile: &'static str,
    pub(super) ok: bool,
    pub(super) status: String,
    pub(super) summary: String,
    pub(super) evidence: ProviderEvidence,
    pub(super) next_actions: Vec<ProviderNextAction>,
    pub(super) truncation: ProviderTruncation,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) error: Option<ProviderOperationError>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderEvidence {
    pub(super) facts: Vec<ProviderFact>,
    pub(super) resources: Vec<ProviderResourceRef>,
    pub(super) collections: Vec<ProviderCollection>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderFact {
    pub(super) field: String,
    pub(super) value: Value,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderResourceRef {
    pub(super) kind: String,
    pub(super) resource_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) version_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) role: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderCollection {
    pub(super) field: String,
    pub(super) total: usize,
    pub(super) returned: usize,
    pub(super) truncated: bool,
    pub(super) items: Vec<ProviderCollectionItem>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderCollectionItem {
    pub(super) facts: Vec<ProviderFact>,
    pub(super) resources: Vec<ProviderResourceRef>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderNextAction {
    pub(super) source: String,
    pub(super) summary: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) operation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) inspect_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) arguments: Option<Value>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderTruncation {
    pub(super) truncated: bool,
    pub(super) omitted_facts: usize,
    pub(super) omitted_resources: usize,
    pub(super) omitted_collections: usize,
    pub(super) omitted_items: usize,
    pub(super) omitted_actions: usize,
    pub(super) serialized_bytes: usize,
    pub(super) max_bytes: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProviderOperationError {
    pub(super) code: String,
    pub(super) category: String,
    pub(super) message: String,
    pub(super) recoverable: bool,
}

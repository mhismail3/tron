//! Model event payloads.

/// Payload for `model.provider_request` events.
pub type ModelProviderRequestPayload =
    crate::shared::protocol::model_audit::ModelProviderRequestAudit;

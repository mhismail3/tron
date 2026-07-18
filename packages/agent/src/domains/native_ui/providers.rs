//! Product-domain data projections for native surfaces.

use serde_json::{Value, json};

use super::Deps;
use crate::domains::session::event_store::types::payloads::compact::CompactBoundaryPayload;
use crate::shared::server::errors::CapabilityError;

pub(crate) fn settings_data(deps: &Deps) -> Value {
    let current = deps.profile_runtime.current();
    let settings = &current.settings;
    let workspace = settings
        .server
        .default_workspace
        .clone()
        .unwrap_or_default();
    let threshold = settings
        .context
        .compactor
        .trigger_token_threshold
        .unwrap_or(settings.context.compactor.compaction_threshold);
    json!({
        "specHash": current.spec_hash(),
        "defaultModel": settings.server.default_model,
        "defaultModelDisplay": settings.server.default_model,
        "defaultWorkspace": workspace,
        "defaultWorkspaceDisplay": if workspace.is_empty() { "Not set" } else { workspace.as_str() },
        "compactionThreshold": threshold,
        "preserveRecentCount": settings.context.compactor.preserve_recent_count,
        "transcriptionEnabled": settings.server.transcription.enabled,
        "tailscaleAddress": settings.server.tailscale_ip,
        "hasTailscaleAddress": settings.server.tailscale_ip.as_ref().is_some_and(|value| !value.is_empty()),
    })
}

pub(crate) fn lab_data() -> Value {
    json!({
        "toggle": true,
        "slider": 0.5,
        "stepper": 3,
        "text": "Native",
        "secure": "",
        "choice": "one",
    })
}

pub(crate) fn compaction_data(
    deps: &Deps,
    session_id: &str,
    event_id: &str,
) -> Result<Value, CapabilityError> {
    let row = deps
        .event_store
        .get_event(event_id)
        .map_err(event_store_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: crate::shared::server::errors::EVENT_NOT_FOUND.to_owned(),
            message: format!("Compaction event {event_id} was not found"),
        })?;
    if row.session_id != session_id {
        return Err(CapabilityError::InvalidParams {
            message: format!("Event {event_id} does not belong to session {session_id}"),
        });
    }
    if row.event_type != "compact.boundary" {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Event {event_id} is {}, expected compact.boundary",
                row.event_type
            ),
        });
    }
    let payload = deps
        .event_store
        .resolve_event_payloads(std::slice::from_ref(&row))
        .map_err(event_store_error)?
        .into_iter()
        .next()
        .ok_or_else(|| CapabilityError::Internal {
            message: format!("Compaction event {event_id} has no payload"),
        })?;
    let compact: CompactBoundaryPayload =
        serde_json::from_value(payload).map_err(|error| CapabilityError::Internal {
            message: format!("Compaction event {event_id} is invalid: {error}"),
        })?;
    let tokens_before = compact.original_tokens.max(0);
    let tokens_after = compact.compacted_tokens.max(0);
    let tokens_saved = tokens_before.saturating_sub(tokens_after);
    let compression_percent = if tokens_before == 0 {
        0.0
    } else {
        (tokens_saved as f64 / tokens_before as f64) * 100.0
    };
    let reason_display = compact
        .reason
        .split('_')
        .map(capitalize)
        .collect::<Vec<_>>()
        .join(" ");
    let summary = compact.summary.unwrap_or_default();
    let has_turn_counts = compact.preserved_turns.is_some() || compact.summarized_turns.is_some();
    let copy_text = format!(
        "Compaction details\nBefore: {}\nAfter: {}\nSaved: {}\nReduction: {:.1}%\nReason: {}{}",
        grouped(tokens_before),
        grouped(tokens_after),
        grouped(tokens_saved),
        compression_percent,
        reason_display,
        if summary.is_empty() {
            String::new()
        } else {
            format!("\n\nSummary\n{summary}")
        }
    );
    Ok(json!({
        "eventId": event_id,
        "sessionId": session_id,
        "eventSequence": row.sequence,
        "tokensBefore": tokens_before,
        "tokensAfter": tokens_after,
        "tokensSaved": tokens_saved,
        "compressionPercent": compression_percent,
        "tokensBeforeDisplay": grouped(tokens_before),
        "tokensAfterDisplay": grouped(tokens_after),
        "tokensSavedDisplay": grouped(tokens_saved),
        "compressionPercentDisplay": format!("{compression_percent:.1}%"),
        "reason": compact.reason,
        "reasonDisplay": reason_display,
        "summary": summary,
        "hasSummary": !summary.is_empty(),
        "preservedTurns": compact.preserved_turns,
        "summarizedTurns": compact.summarized_turns,
        "preservedTurnsDisplay": compact.preserved_turns.map_or_else(|| "—".to_owned(), |value| value.to_string()),
        "summarizedTurnsDisplay": compact.summarized_turns.map_or_else(|| "—".to_owned(), |value| value.to_string()),
        "hasTurnCounts": has_turn_counts,
        "contextControlActionResourceId": compact.context_control_action_resource_id,
        "copyText": copy_text,
    }))
}

fn capitalize(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn grouped(value: i64) -> String {
    let digits = value.unsigned_abs().to_string();
    let mut output = String::with_capacity(digits.len() + digits.len() / 3 + 1);
    if value < 0 {
        output.push('-');
    }
    let first = digits.len() % 3;
    if first > 0 {
        output.push_str(&digits[..first]);
        if digits.len() > first {
            output.push(',');
        }
    }
    for (index, chunk) in digits.as_bytes()[first..].chunks(3).enumerate() {
        if index > 0 {
            output.push(',');
        }
        output.push_str(std::str::from_utf8(chunk).expect("ASCII digits"));
    }
    output
}

fn event_store_error(
    error: crate::domains::session::event_store::EventStoreError,
) -> CapabilityError {
    crate::shared::server::error_mapping::map_event_store_error(error)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grouping_is_stable() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(999), "999");
        assert_eq!(grouped(1_234_567), "1,234,567");
    }
}

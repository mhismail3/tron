//! Offline replay roundtrip verifier for canonical replay manifests.
//!
//! The verifier rebuilds a session audit summary from one manifest value,
//! recomputes section hashes and the overall replay hash, and validates
//! cross-record references. It deliberately has no event-store, engine, model,
//! tool, file, process, queue, stream, or resource handles, so it cannot perform
//! provider re-contact or side effects while proving replay integrity.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::{Map, Value};

use super::{REPLAY_MANIFEST_FORMAT, canonical_hash};
use crate::shared::server::errors::CapabilityError;

/// Successful offline roundtrip report for one replay manifest.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReplayRoundtripReport {
    /// Manifest format.
    pub(crate) format: String,
    /// Session reconstructed from the manifest.
    pub(crate) session_id: String,
    /// Replay hash stored in the manifest.
    pub(crate) replay_hash: String,
    /// Replay hash recomputed from the manifest without its `replayHash` field.
    pub(crate) recomputed_replay_hash: String,
    /// Section hashes recomputed from manifest sections.
    pub(crate) recomputed_section_hashes: BTreeMap<String, String>,
    /// Section-hash mismatches. Successful reports keep this empty.
    pub(crate) section_hash_mismatches: Vec<String>,
    /// Durable section counts reconstructed during roundtrip.
    pub(crate) counts: ReplayRoundtripCounts,
    /// Cross-record reference proof reconstructed during roundtrip.
    pub(crate) cross_record_references: ReplayRoundtripReferences,
}

/// Durable section counts reconstructed by the offline harness.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReplayRoundtripCounts {
    /// Session event count.
    pub(crate) session_events: usize,
    /// Provider audit event count.
    pub(crate) provider_audits: usize,
    /// Trace record count.
    pub(crate) trace_records: usize,
    /// Engine idempotency entry count.
    pub(crate) engine_idempotency_entries: usize,
    /// Engine invocation count.
    pub(crate) engine_invocations: usize,
    /// Engine stream row count.
    pub(crate) engine_streams: usize,
    /// Engine queue row count.
    pub(crate) engine_queue_items: usize,
}

/// Cross-record reference proof reconstructed by the offline harness.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReplayRoundtripReferences {
    /// Provider audits whose event id resolves to a session event.
    pub(crate) provider_audit_event_refs: usize,
    /// Trace records carrying request/result hashes in their trace JSON.
    pub(crate) trace_hash_refs: usize,
    /// Idempotency entries carrying request and outcome hashes.
    pub(crate) idempotency_hash_refs: usize,
    /// Queue payload hashes and attempt invocation references.
    pub(crate) queue_hash_refs: usize,
    /// Stream payload hashes and parent invocation references.
    pub(crate) stream_hash_refs: usize,
    /// Invocation result hashes and idempotency references.
    pub(crate) invocation_hash_refs: usize,
    /// Cross-record reference errors. Successful reports keep this empty.
    pub(crate) cross_record_reference_errors: Vec<String>,
}

/// Rebuild and verify a canonical replay manifest without side effects.
pub(crate) fn roundtrip_manifest(
    manifest: &Value,
) -> Result<ReplayRoundtripReport, CapabilityError> {
    let manifest_object = object(manifest, "manifest")?;
    let format = required_str(manifest_object, "format", "manifest")?;
    if format != REPLAY_MANIFEST_FORMAT {
        return Err(invalid(format!(
            "unsupported replay manifest format: {format}"
        )));
    }
    let session_id = required_str(manifest_object, "sessionId", "manifest")?;
    let replay_hash = required_str(manifest_object, "replayHash", "manifest")?;
    let sections = object(
        manifest_object
            .get("sections")
            .ok_or_else(|| invalid("manifest missing sections"))?,
        "sections",
    )?;
    let section_hashes = object(
        manifest_object
            .get("sectionHashes")
            .ok_or_else(|| invalid("manifest missing sectionHashes"))?,
        "sectionHashes",
    )?;

    let recomputed_section_hashes = recompute_section_hashes(sections)?;
    let section_hash_mismatches =
        compare_section_hashes(section_hashes, &recomputed_section_hashes);
    if !section_hash_mismatches.is_empty() {
        return Err(invalid(format!(
            "replay section hash mismatch: {}",
            section_hash_mismatches.join("; ")
        )));
    }

    let recomputed_replay_hash = recompute_replay_hash(manifest)?;
    if recomputed_replay_hash != replay_hash {
        return Err(invalid(format!(
            "replay hash mismatch: stored {replay_hash}, recomputed {recomputed_replay_hash}"
        )));
    }

    let counts = count_sections(sections)?;
    let cross_record_references = validate_cross_record_references(sections, session_id)?;
    if !cross_record_references
        .cross_record_reference_errors
        .is_empty()
    {
        return Err(invalid(format!(
            "replay cross-record reference failure: {}",
            cross_record_references
                .cross_record_reference_errors
                .join("; ")
        )));
    }

    Ok(ReplayRoundtripReport {
        format: format.to_owned(),
        session_id: session_id.to_owned(),
        replay_hash: replay_hash.to_owned(),
        recomputed_replay_hash,
        recomputed_section_hashes,
        section_hash_mismatches,
        counts,
        cross_record_references,
    })
}

fn recompute_section_hashes(
    sections: &Map<String, Value>,
) -> Result<BTreeMap<String, String>, CapabilityError> {
    let mut hashes = BTreeMap::new();
    for (name, section) in sections {
        hashes.insert(name.clone(), canonical_hash(section)?);
    }
    Ok(hashes)
}

fn compare_section_hashes(
    section_hashes: &Map<String, Value>,
    recomputed: &BTreeMap<String, String>,
) -> Vec<String> {
    let mut mismatches = Vec::new();
    for (name, recomputed_hash) in recomputed {
        match section_hashes.get(name).and_then(Value::as_str) {
            Some(stored_hash) if stored_hash == recomputed_hash => {}
            Some(stored_hash) => mismatches.push(format!(
                "{name}: stored {stored_hash}, recomputed {recomputed_hash}"
            )),
            None => mismatches.push(format!("{name}: missing stored hash")),
        }
    }
    for name in section_hashes.keys() {
        if !recomputed.contains_key(name) {
            mismatches.push(format!("{name}: hash has no matching section"));
        }
    }
    mismatches
}

fn recompute_replay_hash(manifest: &Value) -> Result<String, CapabilityError> {
    let mut without_hash = manifest.clone();
    object_mut(&mut without_hash, "manifest")?.remove("replayHash");
    canonical_hash(&without_hash)
}

fn count_sections(sections: &Map<String, Value>) -> Result<ReplayRoundtripCounts, CapabilityError> {
    Ok(ReplayRoundtripCounts {
        session_events: array(sections, "sessionEvents")?.len(),
        provider_audits: array(sections, "providerAudits")?.len(),
        trace_records: array(sections, "traceRecords")?.len(),
        engine_idempotency_entries: array(sections, "engineIdempotencyEntries")?.len(),
        engine_invocations: array(sections, "engineInvocations")?.len(),
        engine_streams: array(sections, "engineStreams")?.len(),
        engine_queue_items: array(sections, "engineQueueItems")?.len(),
    })
}

fn validate_cross_record_references(
    sections: &Map<String, Value>,
    session_id: &str,
) -> Result<ReplayRoundtripReferences, CapabilityError> {
    let session_events = array(sections, "sessionEvents")?;
    let provider_audits = array(sections, "providerAudits")?;
    let trace_records = array(sections, "traceRecords")?;
    let idempotency_entries = array(sections, "engineIdempotencyEntries")?;
    let invocations = array(sections, "engineInvocations")?;
    let streams = array(sections, "engineStreams")?;
    let queue_items = array(sections, "engineQueueItems")?;

    let session_event_ids = session_events
        .iter()
        .filter_map(|event| event.get("id").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let invocation_ids = invocations
        .iter()
        .filter_map(|record| record.get("invocationId").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let idempotency_keys = idempotency_entries
        .iter()
        .filter_map(idempotency_reference_key)
        .collect::<BTreeSet<_>>();

    let mut refs = ReplayRoundtripReferences::default();
    let mut errors = Vec::new();

    for event in session_events {
        if event.get("sessionId").and_then(Value::as_str) != Some(session_id) {
            errors.push("sessionEvents contains an event outside the manifest session".to_owned());
        }
    }

    for audit in provider_audits {
        match audit.get("eventId").and_then(Value::as_str) {
            Some(event_id) if session_event_ids.contains(event_id) => {
                refs.provider_audit_event_refs += 1;
            }
            Some(event_id) => errors.push(format!(
                "provider audit references missing session event {event_id}"
            )),
            None => errors.push("provider audit is missing eventId".to_owned()),
        }
    }

    for trace in trace_records {
        if let Some(trace_session_id) = trace.get("sessionId").and_then(Value::as_str)
            && trace_session_id != session_id
        {
            errors.push(format!(
                "trace {} belongs to session {trace_session_id}",
                display_id(trace)
            ));
        }
        let metadata = trace
            .get("recordJson")
            .and_then(|record| record.get("metadata"))
            .and_then(|metadata| metadata.get("dev.tron"));
        match metadata {
            Some(metadata)
                if metadata
                    .get("requestHash")
                    .and_then(Value::as_str)
                    .is_some()
                    && trace_result_hash_present(trace, metadata) =>
            {
                refs.trace_hash_refs += 1;
            }
            _ => errors.push(format!(
                "trace {} is missing requestHash/resultHash replay metadata",
                display_id(trace)
            )),
        }
    }

    for entry in idempotency_entries {
        let request_hash = entry.get("requestHash").and_then(Value::as_str);
        let payload_fingerprint = entry.get("payloadFingerprint").and_then(Value::as_str);
        if request_hash.is_none() || request_hash != payload_fingerprint {
            errors.push(format!(
                "idempotency entry {} is missing a payload fingerprint requestHash",
                display_id(entry)
            ));
        }
        if entry.get("outcome").is_some()
            && !entry.get("outcome").is_some_and(Value::is_null)
            && entry.get("outcomeHash").and_then(Value::as_str).is_none()
        {
            errors.push(format!(
                "idempotency entry {} has outcome without outcomeHash",
                display_id(entry)
            ));
        }
        let scope = entry.get("scope").and_then(Value::as_object);
        let session_scoped = scope
            .and_then(|scope| Some((scope.get("kind")?.as_str()?, scope.get("value")?.as_str()?)))
            .is_some_and(|(kind, value)| kind == "session" && value == session_id);
        let first_invocation = entry.get("firstInvocationId").and_then(Value::as_str);
        let latest_invocation = entry.get("latestInvocationId").and_then(Value::as_str);
        if !session_scoped
            && !first_invocation.is_some_and(|id| invocation_ids.contains(id))
            && !latest_invocation.is_some_and(|id| invocation_ids.contains(id))
        {
            errors.push(format!(
                "idempotency entry {} is not session-scoped and has no session invocation ref",
                display_id(entry)
            ));
        }
        refs.idempotency_hash_refs += 1;
    }

    for invocation in invocations {
        let has_result = invocation
            .get("resultValue")
            .is_some_and(|value| !value.is_null())
            || invocation
                .get("error")
                .is_some_and(|value| !value.is_null());
        if has_result
            && invocation
                .get("resultHash")
                .and_then(Value::as_str)
                .is_none()
        {
            errors.push(format!(
                "invocation {} has result/error without resultHash",
                display_id(invocation)
            ));
        }
        if let Some(key) = invocation.get("idempotencyKey").and_then(Value::as_str) {
            match invocation_reference_key(invocation, key) {
                Some(reference_key) if idempotency_keys.contains(&reference_key) => {}
                Some(reference_key) => errors.push(format!(
                    "invocation {} references missing idempotency entry {reference_key}",
                    display_id(invocation)
                )),
                None => errors.push(format!(
                    "invocation {} has idempotencyKey without idempotencyScope",
                    display_id(invocation)
                )),
            }
        }
        refs.invocation_hash_refs += 1;
    }

    for item in queue_items {
        if item.get("payloadHash").and_then(Value::as_str).is_none() {
            errors.push(format!(
                "queue item {} is missing payloadHash",
                display_id(item)
            ));
        }
        for attempt in item
            .get("attemptRecords")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            for field in ["resultInvocationId", "replayedFromInvocationId"] {
                if let Some(invocation_id) = attempt.get(field).and_then(Value::as_str)
                    && !invocation_ids.contains(invocation_id)
                {
                    errors.push(format!(
                        "queue item {} attempt references missing invocation {invocation_id}",
                        display_id(item)
                    ));
                }
            }
        }
        refs.queue_hash_refs += 1;
    }

    for stream in streams {
        if stream.get("payloadHash").and_then(Value::as_str).is_none() {
            errors.push(format!(
                "stream row {} is missing payloadHash",
                display_id(stream)
            ));
        }
        if let Some(parent_invocation_id) = stream.get("parentInvocationId").and_then(Value::as_str)
            && !invocation_ids.contains(parent_invocation_id)
        {
            errors.push(format!(
                "stream row {} references missing parent invocation {parent_invocation_id}",
                display_id(stream)
            ));
        }
        refs.stream_hash_refs += 1;
    }

    refs.cross_record_reference_errors = errors;
    Ok(refs)
}

fn idempotency_reference_key(entry: &Value) -> Option<String> {
    let scope = entry.get("scope")?.as_object()?;
    Some(format!(
        "{}:{}:{}:{}",
        entry.get("functionId")?.as_str()?,
        scope.get("kind")?.as_str()?,
        scope.get("value")?.as_str()?,
        entry.get("key")?.as_str()?,
    ))
}

fn invocation_reference_key(invocation: &Value, key: &str) -> Option<String> {
    let scope = invocation.get("idempotencyScope")?.as_object()?;
    Some(format!(
        "{}:{}:{}:{key}",
        invocation.get("functionId")?.as_str()?,
        scope.get("kind")?.as_str()?,
        scope.get("value")?.as_str()?,
    ))
}

fn trace_result_hash_present(trace: &Value, metadata: &Value) -> bool {
    let status = trace.get("status").and_then(Value::as_str);
    status == Some("running") || metadata.get("resultHash").and_then(Value::as_str).is_some()
}

fn array<'a>(
    sections: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a Vec<Value>, CapabilityError> {
    sections
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid(format!("sections.{key} must be an array")))
}

fn object<'a>(value: &'a Value, label: &str) -> Result<&'a Map<String, Value>, CapabilityError> {
    value
        .as_object()
        .ok_or_else(|| invalid(format!("{label} must be an object")))
}

fn object_mut<'a>(
    value: &'a mut Value,
    label: &str,
) -> Result<&'a mut Map<String, Value>, CapabilityError> {
    value
        .as_object_mut()
        .ok_or_else(|| invalid(format!("{label} must be an object")))
}

fn required_str<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    label: &str,
) -> Result<&'a str, CapabilityError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label}.{key} must be a string")))
}

fn display_id(value: &Value) -> String {
    for key in ["id", "invocationId", "receiptId", "key", "cursor"] {
        if let Some(value) = value.get(key) {
            if let Some(value) = value.as_str() {
                return value.to_owned();
            }
            if let Some(value) = value.as_u64() {
                return value.to_string();
            }
        }
    }
    "<unknown>".to_owned()
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

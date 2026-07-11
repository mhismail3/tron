//! Structural byte-budget reduction for canonical provider outputs.
//!
//! Required semantic collections retain their newest item and core navigation
//! facts. Optional items, facts, resources, actions, and summary text are
//! reduced in that order with exact omission counters.

use crate::shared::foundation::text::truncate_str;

use super::types::{PROVIDER_OUTPUT_MAX_BYTES, ProviderOperationOutput};

pub(super) fn fit_output_budget(
    output: &mut ProviderOperationOutput,
    required_fact_fields: &[&str],
    expected_collection_fields: &[&str],
) -> Result<(), String> {
    loop {
        let encoded_len = stabilize_serialized_byte_count(output)?;
        if encoded_len <= PROVIDER_OUTPUT_MAX_BYTES {
            return Ok(());
        }
        output.truncation.truncated = true;
        if trim_collection_item(output, expected_collection_fields) {
            output.truncation.omitted_items += 1;
        } else if trim_collection_item_evidence(output, expected_collection_fields) {
            output.truncation.omitted_facts += 1;
        } else if let Some(index) = output.evidence.collections.iter().rposition(|collection| {
            !expected_collection_fields.contains(&collection.field.as_str())
        }) {
            let collection = output.evidence.collections.remove(index);
            output.truncation.omitted_collections += 1;
            output.truncation.omitted_items += collection.returned;
        } else if let Some(index) = output
            .evidence
            .facts
            .iter()
            .rposition(|fact| !required_fact_fields.contains(&fact.field.as_str()))
        {
            output.evidence.facts.remove(index);
            output.truncation.omitted_facts += 1;
        } else if output.evidence.resources.pop().is_some() {
            output.truncation.omitted_resources += 1;
        } else if output.next_actions.pop().is_some() {
            output.truncation.omitted_actions += 1;
        } else if output.summary.len() > 240 {
            output.summary = truncate_str(&output.summary, output.summary.len() / 2).to_owned();
        } else {
            return Err("minimal provider output exceeds structural byte budget".to_owned());
        }
    }
}

fn trim_collection_item(
    output: &mut ProviderOperationOutput,
    expected_collection_fields: &[&str],
) -> bool {
    let Some(collection) = output
        .evidence
        .collections
        .iter_mut()
        .rev()
        .find(|collection| {
            let minimum =
                usize::from(expected_collection_fields.contains(&collection.field.as_str()));
            collection.items.len() > minimum
        })
    else {
        return false;
    };
    collection.items.pop();
    collection.returned = collection.items.len();
    collection.truncated = collection.total > collection.returned;
    true
}

fn trim_collection_item_evidence(
    output: &mut ProviderOperationOutput,
    expected_collection_fields: &[&str],
) -> bool {
    let Some(item) = output
        .evidence
        .collections
        .iter_mut()
        .rev()
        .filter(|collection| expected_collection_fields.contains(&collection.field.as_str()))
        .filter_map(|collection| collection.items.last_mut())
        .find(|item| {
            item.facts
                .iter()
                .any(|fact| !core_collection_fact(&fact.field))
        })
    else {
        return false;
    };
    if let Some(index) = item
        .facts
        .iter()
        .rposition(|fact| !core_collection_fact(&fact.field))
    {
        item.facts.remove(index);
        return true;
    }
    false
}

fn core_collection_fact(field: &str) -> bool {
    matches!(
        field,
        "traceRecordId"
            | "traceId"
            | "invocationId"
            | "operation"
            | "status"
            | "kind"
            | "resourceId"
            | "versionId"
    )
}

fn stabilize_serialized_byte_count(output: &mut ProviderOperationOutput) -> Result<usize, String> {
    for _ in 0..8 {
        let encoded_len = serde_json::to_vec(&*output)
            .map_err(|error| format!("measure provider output: {error}"))?
            .len();
        if output.truncation.serialized_bytes == encoded_len {
            return Ok(encoded_len);
        }
        output.truncation.serialized_bytes = encoded_len;
    }
    Err("provider output serialized byte count did not converge".to_owned())
}

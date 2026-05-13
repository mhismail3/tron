//! Tree linearization and turn derivation.
//!
//! Claude Code records form a tree via `uuid`/`parentUuid`. At each fork
//! point the child with the latest timestamp is selected, producing a
//! single linear conversation path. Turn numbers are derived from
//! `promptId` transitions.

use std::collections::HashMap;

use crate::domains::import::types::{ClaudeRecord, RecordKind};

/// A linearized record with its assigned turn number.
#[derive(Debug)]
pub struct LinearRecord {
    /// The original Claude Code record.
    pub record: ClaudeRecord,
    /// Turn number (1-based, derived from `promptId` transitions).
    pub turn: i64,
}

/// Linearize a Claude Code record tree into a conversation sequence.
///
/// 1. Builds a parent→children map from `uuid`/`parentUuid`.
/// 2. Walks from the root (parentUuid = None), picking the latest-timestamp
///    child at each fork.
/// 3. Filters out non-conversation records (progress, file-history-snapshot,
///    attachment).
/// 4. Assigns turn numbers based on `promptId` transitions.
pub fn linearize(records: Vec<ClaudeRecord>) -> Vec<LinearRecord> {
    // Separate records that participate in the UUID tree from those that don't.
    let (tree_records, non_tree) = partition_tree_records(records);

    // Build parent→children map.
    let mut children: HashMap<Option<String>, Vec<ClaudeRecord>> = HashMap::new();
    for record in tree_records {
        children
            .entry(record.parent_uuid.clone())
            .or_default()
            .push(record);
    }

    // Walk from root, always picking latest timestamp at forks.
    let linear_chain = walk_tree(&children);

    // Filter and assign turns.
    let mut result = assign_turns(linear_chain);

    // Append custom-title records at the end so the assembler can extract them.
    for record in non_tree {
        if record.kind() == RecordKind::CustomTitle {
            result.push(LinearRecord { record, turn: 0 });
        }
    }

    result
}

/// Partition records into tree participants and non-tree (metadata/no uuid).
///
/// Records without uuid AND metadata record types (custom-title, agent-name,
/// last-prompt, queue-operation, permission-mode) go to non-tree even if they
/// have a uuid, since they're not conversation participants.
fn partition_tree_records(records: Vec<ClaudeRecord>) -> (Vec<ClaudeRecord>, Vec<ClaudeRecord>) {
    let mut tree = Vec::new();
    let mut non_tree = Vec::new();

    for record in records {
        let kind = record.kind();
        let is_metadata = matches!(
            kind,
            RecordKind::CustomTitle
                | RecordKind::AgentName
                | RecordKind::LastPrompt
                | RecordKind::QueueOperation
                | RecordKind::PermissionMode
        );

        if record.uuid.is_some() && !is_metadata {
            tree.push(record);
        } else {
            non_tree.push(record);
        }
    }

    (tree, non_tree)
}

/// Walk the tree from root, picking the latest-timestamp child at each fork.
fn walk_tree(children: &HashMap<Option<String>, Vec<ClaudeRecord>>) -> Vec<ClaudeRecord> {
    let mut result = Vec::new();
    let mut current_parent: Option<String> = None;

    loop {
        let Some(kids) = children.get(&current_parent) else {
            break;
        };
        if kids.is_empty() {
            break;
        }

        // Pick the child with the latest timestamp.
        let chosen = kids
            .iter()
            .max_by(|a, b| {
                let ts_a = a.timestamp.as_deref().unwrap_or("");
                let ts_b = b.timestamp.as_deref().unwrap_or("");
                ts_a.cmp(ts_b)
            })
            .unwrap();

        current_parent = chosen.uuid.clone();
        result.push(chosen.clone());
    }

    result
}

/// Filter non-conversation records and assign turn numbers.
fn assign_turns(chain: Vec<ClaudeRecord>) -> Vec<LinearRecord> {
    let mut result = Vec::new();
    let mut current_turn: i64 = 0;
    let mut last_prompt_id: Option<String> = None;

    for record in chain {
        let kind = record.kind();

        // Skip non-conversation records.
        match kind {
            RecordKind::Progress | RecordKind::Attachment | RecordKind::FileHistorySnapshot => {
                continue;
            }
            _ => {}
        }

        // Advance turn on new promptId from non-meta user records.
        if kind == RecordKind::User
            && record.is_meta != Some(true)
            && !record.is_capability_result()
            && let Some(pid) = &record.prompt_id
            && last_prompt_id.as_ref() != Some(pid)
        {
            current_turn += 1;
            last_prompt_id = Some(pid.clone());
        }

        result.push(LinearRecord {
            record,
            turn: current_turn.max(1), // ensure at least turn 1
        });
    }

    result
}

#[cfg(test)]
#[path = "tree_tests.rs"]
mod tests;

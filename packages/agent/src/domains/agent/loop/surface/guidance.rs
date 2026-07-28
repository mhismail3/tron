//! Compact model guidance derived from the exact resolved tool surface.

/// Build provider-turn awareness without duplicating the live catalog.
pub(crate) fn surface_context_primer(
    snapshot: &crate::domains::worker_kernel::EngineSurfaceSnapshot,
) -> String {
    let projected = snapshot
        .tools
        .iter()
        .filter(|tool| tool.worker_id.is_some())
        .map(|tool| {
            let identity = match &tool.worker_version {
                Some(version) => format!("{}@{}", tool.model_name, short_hash(version)),
                None => tool.model_name.clone(),
            };
            let evidence = tool.worker_id.as_deref().and_then(|worker_id| {
                snapshot
                    .available_workers
                    .iter()
                    .find(|worker| worker.worker_id == worker_id)
            });
            evidence.map_or(identity.clone(), |worker| {
                let reason = worker.selection_reason.as_deref().unwrap_or("available");
                format!("{identity} [{reason}; runs={}]", worker.completed_runs)
            })
        })
        .collect::<Vec<_>>();
    let projected = if projected.is_empty() {
        "none".to_owned()
    } else {
        projected.join(", ")
    };
    let discovery_hint = snapshot
        .tools
        .iter()
        .any(|tool| tool.model_name == "worker_discover")
        .then_some(
            " Use worker_discover when a dynamic capability is omitted. Use Engine Steward for worker diagnosis and Worker Forge for worker changes; permanent deletion, secret rotation, and engine-wide stop remain authenticated dashboard actions.",
        )
        .unwrap_or_default();
    format!(
        "Engine surface r{} · {} fixed tools · {}/{} workers projected · surface {} · projected: {}.{}",
        snapshot.catalog_revision,
        snapshot.fixed_tool_count,
        snapshot.projected_worker_count,
        snapshot.available_worker_count,
        short_hash(&snapshot.surface_hash),
        projected,
        discovery_hint,
    )
}

fn short_hash(value: &str) -> &str {
    value.get(..8).unwrap_or(value)
}

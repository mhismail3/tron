//! Compact model guidance derived from the exact resolved tool surface.

/// Build stable provider-turn guidance without duplicating the live catalog.
pub(crate) fn surface_context_primer(
    snapshot: &crate::domains::worker_kernel::EngineSurfaceSnapshot,
) -> String {
    let has_discovery = snapshot
        .tools
        .iter()
        .any(|tool| tool.model_name == "worker_discover");
    if has_discovery {
        "Use only the typed tools supplied in this request. Use worker_discover when a dynamic \
         capability is omitted. Use Engine Steward for worker diagnosis and Worker Forge for \
         worker changes; permanent deletion, secret rotation, and engine-wide stop remain \
         authenticated dashboard actions."
            .to_owned()
    } else {
        "Use only the typed tools supplied in this request.".to_owned()
    }
}

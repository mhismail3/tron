//! Compact model guidance derived from the exact resolved tool surface.

/// Build stable provider-turn guidance without duplicating the live catalog.
pub(crate) fn surface_context_primer(
    snapshot: &crate::domains::worker_kernel::EngineSurfaceSnapshot,
) -> String {
    let has_discovery = snapshot
        .tools
        .iter()
        .any(|tool| tool.model_name == "worker_discover");
    let has_invoke = snapshot
        .tools
        .iter()
        .any(|tool| tool.model_name == "worker_invoke");
    if has_discovery {
        let direct_invocation = if has_invoke {
            " When the caller supplies an exact worker id, invoke it directly with worker_invoke \
             rather than delegating merely to launch it."
        } else {
            ""
        };
        format!(
            "Use only the typed tools supplied in this request. Use worker_discover when a dynamic \
             capability is omitted.{direct_invocation} For worker diagnosis or changes, discover \
             a current healthy diagnostic or authoring capability instead of assuming that an \
             optional worker is installed; permanent deletion, secret rotation, and engine-wide \
             stop remain authenticated dashboard actions."
        )
    } else {
        "Use only the typed tools supplied in this request.".to_owned()
    }
}

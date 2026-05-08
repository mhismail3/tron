//! Canonical function inventory for the prompt_library domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "prompt_library::history_list",
    "prompt_library::history_delete",
    "prompt_library::history_clear",
    "prompt_library::snippet_list",
    "prompt_library::snippet_get",
    "prompt_library::snippet_create",
    "prompt_library::snippet_update",
    "prompt_library::snippet_delete",
];

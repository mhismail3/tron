//! Canonical function inventory for the tree domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "tree::get_visualization",
    "tree::get_branches",
    "tree::get_subtree",
    "tree::get_ancestors",
    "tree::compare_branches",
];

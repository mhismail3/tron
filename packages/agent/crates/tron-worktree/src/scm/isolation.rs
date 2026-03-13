//! Isolation policy — when to create worktrees.

use crate::types::IsolationMode;

/// Determine whether a session should get its own worktree.
pub fn should_isolate(
    mode: &IsolationMode,
    is_git_repo: bool,
    active_count_for_repo: usize,
    force: bool,
) -> bool {
    match mode {
        IsolationMode::Never => false,
        IsolationMode::Always => is_git_repo,
        IsolationMode::Lazy => is_git_repo && (force || active_count_for_repo > 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_mode() {
        assert!(!should_isolate(&IsolationMode::Never, true, 5, true));
        assert!(!should_isolate(&IsolationMode::Never, false, 0, false));
    }

    #[test]
    fn always_mode_git_repo() {
        assert!(should_isolate(&IsolationMode::Always, true, 0, false));
        assert!(should_isolate(&IsolationMode::Always, true, 3, false));
    }

    #[test]
    fn always_mode_non_git() {
        assert!(!should_isolate(&IsolationMode::Always, false, 0, false));
        assert!(!should_isolate(&IsolationMode::Always, false, 5, true));
    }

    #[test]
    fn lazy_mode_no_others() {
        assert!(!should_isolate(&IsolationMode::Lazy, true, 0, false));
    }

    #[test]
    fn lazy_mode_others_active() {
        assert!(should_isolate(&IsolationMode::Lazy, true, 1, false));
        assert!(should_isolate(&IsolationMode::Lazy, true, 3, false));
    }

    #[test]
    fn lazy_mode_force() {
        assert!(should_isolate(&IsolationMode::Lazy, true, 0, true));
    }

    #[test]
    fn lazy_mode_non_git() {
        assert!(!should_isolate(&IsolationMode::Lazy, false, 5, true));
    }
}

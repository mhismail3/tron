//! Worktree operation implementations.
//!
//! The worktree worker owns repository/worktree reads, safe index operations,
//! high-risk branch and merge workflows, leases, compensation metadata, and git
//! stream publication. Git helpers that are reused by `git::*` stay explicit
//! public domain services rather than central dispatcher branches.

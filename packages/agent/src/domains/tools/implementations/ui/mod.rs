//! # tools/ui — user-facing tools
//!
//! Tools that surface an interaction point to the user (iOS app or
//! macOS GUI) rather than manipulating state silently. Every tool here
//! emits events that the iOS plugin system renders into a bespoke chip.
//!
//! ## Submodules
//!
//! | Module              | Tool             | Content |
//! |---------------------|------------------|---------|
//! | [`ask_user`]        | `AskUserQuestion` | Pose a question with typed answer choices; blocks the turn until iOS responds |
//! | [`notify`]          | `NotifyApp`       | Record an engine inbox notification and send an APNS push when configured |
//! | [`computer_use`]    | `ComputerUse`     | macOS GUI automation (screenshot, click, type, scroll) — see submodule docs |
//! | [`display`]         | `Display`         | Render structured content (markdown, code, table) in the iOS chat |
//! | [`display_stream`]  | —                | Helper for incremental `Display` updates during long turns |
//! | [`input`] (macOS)   | —                | Native `enigo`-based input primitives used by `ComputerUse` |
//!
//! ## Invariants
//!
//! - User decisions for engine policy approvals are owned by the engine
//!   `approval::*` primitives. UI tools here only ask product questions or
//!   surface notifications.
//! - [`notify`] always records an engine-owned inbox item through the
//!   session event stream. When APNS is not configured, the tool returns
//!   a warning the agent surfaces, but does not error, so session flow
//!   never depends on push availability.

pub mod ask_user;
pub mod computer_use;
pub mod display;
pub mod display_stream;
#[cfg(target_os = "macos")]
pub mod input;
pub mod notify;

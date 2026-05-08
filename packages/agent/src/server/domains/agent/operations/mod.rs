//! Agent operation implementations.
//!
//! The agent worker owns prompt acceptance, queued prompt startup, run-turn
//! launch, agent queue control, confirmations, answers, aborts, and subagent
//! result delivery. `handlers.rs` binds one contract operation key to each
//! operation; this module is the vertical home for splitting those flows as the
//! agent runtime continues to shrink around canonical engine functions.

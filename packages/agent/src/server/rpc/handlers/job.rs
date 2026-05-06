//! Job RPC compatibility module.
//!
//! `job.background`, `job.cancel`, `job.list`, `job.subscribe`, and
//! `job.unsubscribe` are collapsed into canonical `job::*` engine functions and
//! registered through generic JSON-RPC trigger markers. Job business behavior
//! now lives in `engine_bridge::functions::job`; this file remains as the
//! progressive disclosure anchor for the RPC module tree.

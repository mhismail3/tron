//! # tools/web — network fetch and search tools
//!
//! Tool implementations that reach the internet, plus the shared HTTP
//! plumbing they rely on.
//!
//! ## Submodules
//!
//! | Module          | Content |
//! |-----------------|---------|
//! | [`web_fetch`]   | `WebFetch` tool — GET a URL, render as markdown, with redirect bounding |
//! | [`web_search`]  | `WebSearch` tool — Brave Search API query with per-call auth lookup |
//! | [`url_validator`] | Parse + scheme/host validation; rejects `file://`, private IPs |
//! | [`html_parser`] | HTML → markdown conversion; script/style/nav stripping |
//! | [`cache`]       | Short-lived in-memory fetch cache keyed on canonical URL |
//!
//! ## Invariants
//!
//! - Every outbound request routes through the injected `HttpClient`
//!   trait ([`crate::tools::traits`]) so tests never hit the real
//!   internet.
//! - `WebSearch` is always registered and reads Brave credentials from
//!   `auth.json` when called, so adding a key does not require a daemon
//!   restart.
//! - [`url_validator::validate_url`] rejects private and link-local
//!   addresses; a `WebFetch` to `http://127.0.0.1:8080/…` returns an
//!   error, not an accidental SSRF.
//! - [`cache`] is opt-in per call; misses are silent, hits log at
//!   `debug` to keep request auditing cheap.

pub mod cache;
pub mod html_parser;
pub mod url_validator;
pub mod web_fetch;
pub mod web_search;

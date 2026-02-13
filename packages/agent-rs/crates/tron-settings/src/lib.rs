//! # tron-settings
//!
//! Configuration management with layered sources for the Tron agent.
//!
//! Uses `figment` for multi-source config resolution:
//! compiled defaults -> `~/.tron/settings.json` -> `TRON_*` env vars.
//!
//! Settings are server-authoritative: `~/.tron/settings.json` is the source of truth.
//! iOS reads/writes via `settings.get`/`settings.update` RPC methods.

#![deny(unsafe_code)]

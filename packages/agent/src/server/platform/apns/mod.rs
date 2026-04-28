//! Push notification delivery via the Cloudflare Worker relay.
//!
//! ## Submodules
//!
//! | Module            | Purpose                                                             |
//! |-------------------|---------------------------------------------------------------------|
//! | [`sender`]        | `PushSender` trait — transport-agnostic send interface              |
//! | [`relay`]         | `RelayClient` — HMAC-signed HTTPS to Cloudflare Worker relay        |
//! | [`relay_delegate`]| `RelayNotifyDelegate` — `NotifyDelegate` impl using relay           |
//! | `config`          | Relay config loading from build-time or runtime env vars            |
//! | `push_helpers`    | Token queries, `(env, bundle_id)` grouping, terminal-error cleanup  |
//! | `types`           | `ApnsNotification`, `ApnsSendResult`                                |
//!
//! ## Transport selection (in `main.rs`)
//!
//! 1. Relay: `TRON_RELAY_URL` + `TRON_RELAY_SECRET` (build-time or runtime env)
//! 2. Disabled: relay not configured → `StubNotifyDelegate`
//!
//! ## Per-token routing
//!
//! Each device token carries its own `environment` (sandbox / production)
//! and `bundle_id` (`com.tron.mobile` vs `com.tron.mobile.beta`). Delegates
//! call [`push_helpers::group_tokens`] to split the active-tokens list by
//! `(environment, bundle_id)` — each group becomes one `send_to_many`
//! request so the relay's single `apns-topic` header is correct for every
//! token in the batch. Mixing bundles in one request reproduces the
//! 2026-04-16 `DeviceTokenNotForTopic` bug.
//!
//! ## Delivery model
//!
//! Every notification fans out to every active device token. This matches
//! the "iPhone + iPad" expectation: if a user has the same app on two
//! devices, both should get the push regardless of which device initiated
//! the session. Cross-app mis-delivery on the same physical device is
//! prevented by the per-bundle `apns-topic` header (above), not by
//! session-scoping.

mod config;
mod push_helpers;
pub mod relay;
pub mod relay_delegate;
pub mod sender;
mod types;

pub use config::{PushConfig, RelayConfig, load_push_config, load_relay_config};
pub use sender::{ApnsBatch, PushSender};
pub use types::{ApnsNotification, ApnsSendResult};

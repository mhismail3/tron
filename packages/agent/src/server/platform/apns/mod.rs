//! Push notification delivery — direct APNs and relay transports.
//!
//! ## Submodules
//!
//! | Module            | Purpose                                                             |
//! |-------------------|---------------------------------------------------------------------|
//! | [`sender`]        | `PushSender` trait — transport-agnostic send interface               |
//! | [`service`]       | `ApnsService` — direct .p8 JWT signing + HTTP/2 to APNs             |
//! | [`relay`]         | `RelayClient` — HMAC-signed HTTPS to Cloudflare Worker relay        |
//! | [`delegate`]      | `ApnsNotifyDelegate` — `NotifyDelegate` impl using direct APNs      |
//! | [`relay_delegate`]| `RelayNotifyDelegate` — `NotifyDelegate` impl using relay           |
//! | `config`          | Config loading: direct (.p8 on disk) vs relay (build-time env)      |
//! | `push_helpers`    | Token queries, `(env, bundle_id)` grouping, terminal-error cleanup  |
//! | `types`           | `ApnsNotification`, `ApnsSendResult`                                |
//!
//! ## Transport selection (in `main.rs`)
//!
//! 1. Direct: `~/.tron/system/deployment/apns.json` + `.p8` key on disk
//! 2. Relay: `TRON_RELAY_URL` + `TRON_RELAY_SECRET` (build-time or runtime env)
//! 3. Disabled: neither configured → `StubNotifyDelegate`
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

pub mod delegate;
mod config;
pub mod relay;
pub mod relay_delegate;
mod push_helpers;
pub mod sender;
mod service;
mod types;

pub use config::{ApnsConfig, load_apns_config, load_push_config, load_relay_config, PushConfig, RelayConfig};
pub use sender::{ApnsBatch, PushSender};
pub use service::ApnsService;
pub use types::{ApnsNotification, ApnsSendResult};

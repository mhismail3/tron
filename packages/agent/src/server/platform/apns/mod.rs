//! Push notification delivery — direct APNs and relay transports.
//!
//! ## Submodules
//!
//! | Module            | Purpose                                                           |
//! |-------------------|-------------------------------------------------------------------|
//! | [`sender`]        | `PushSender` trait — transport-agnostic send interface             |
//! | [`service`]       | `ApnsService` — direct .p8 JWT signing + HTTP/2 to APNs           |
//! | [`relay`]         | `RelayClient` — HMAC-signed HTTPS to Cloudflare Worker relay      |
//! | [`delegate`]      | `ApnsNotifyDelegate` — `NotifyDelegate` impl using direct APNs    |
//! | [`relay_delegate`]| `RelayNotifyDelegate` — `NotifyDelegate` impl using relay         |
//! | `config`          | Config loading: direct (.p8 on disk) vs relay (build-time env)    |
//! | `push_helpers`    | Shared helpers: token queries, notification conversion, 410 cleanup|
//! | `types`           | `ApnsNotification`, `ApnsSendResult`                              |
//!
//! ## Transport selection (in `main.rs`)
//!
//! 1. Direct: `~/.tron/system/mods/apns/config.json` + `.p8` key on disk
//! 2. Relay: `TRON_RELAY_URL` + `TRON_RELAY_SECRET` (build-time or runtime env)
//! 3. Disabled: neither configured → `StubNotifyDelegate`

pub mod delegate;
mod config;
pub mod relay;
pub mod relay_delegate;
mod push_helpers;
pub mod sender;
mod service;
mod types;

pub use config::{ApnsConfig, load_apns_config, load_push_config, load_relay_config, PushConfig, RelayConfig};
pub use sender::PushSender;
pub use service::ApnsService;
pub use types::{ApnsNotification, ApnsSendResult};

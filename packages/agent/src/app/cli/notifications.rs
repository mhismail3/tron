//! Notification relay and direct-APNs credential commands.

use super::*;

pub(super) fn notifications_auth_cli(action: &NotificationsAction) -> Result<()> {
    use crate::domains::auth::credentials::{
        NotificationRelayCredentials, NotificationTransportMode,
        clear_notification_relay_credentials, load_notification_push_config,
        save_notification_relay_credentials, set_notification_transport_mode,
    };

    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    match action {
        NotificationsAction::ConfigureRelay { url, secret_file } => {
            let secret = std::fs::read_to_string(secret_file).with_context(|| {
                format!(
                    "Failed to read notification relay secret at {}",
                    secret_file.display()
                )
            })?;
            let config = save_notification_relay_credentials(
                &path,
                NotificationRelayCredentials {
                    url: url.trim().to_owned(),
                    secret: secret.trim().to_owned(),
                },
            )
            .context("Failed to save notification relay credentials")?;
            print_notification_transport_status(&path, Some(config))?;
            eprintln!("Notification relay configured and selected.");
            Ok(())
        }
        NotificationsAction::Status => {
            let config = load_notification_push_config(&path)
                .context("Failed to load notification transport configuration")?;
            print_notification_transport_status(&path, config)
        }
        NotificationsAction::Use { mode } => {
            let mode = match mode.as_str() {
                "relay" => NotificationTransportMode::Relay,
                "direct" => NotificationTransportMode::Direct,
                _ => bail!("Notification transport mode must be relay or direct"),
            };
            let config = set_notification_transport_mode(&path, mode)
                .context("Failed to select notification transport")?;
            print_notification_transport_status(&path, Some(config))?;
            eprintln!("Notification transport selected: {}.", mode.as_str());
            Ok(())
        }
        NotificationsAction::ClearRelay => {
            let changed = clear_notification_relay_credentials(&path)
                .context("Failed to clear notification relay credentials")?;
            let config = load_notification_push_config(&path)
                .context("Failed to reload notification transport configuration")?;
            print_notification_transport_status(&path, config)?;
            eprintln!(
                "Notification relay credentials {}.",
                if changed {
                    "cleared"
                } else {
                    "were not configured"
                }
            );
            Ok(())
        }
        NotificationsAction::ImportLegacyEnvironment => {
            if let Some(config) = load_notification_push_config(&path)
                .context("Failed to load notification transport configuration")?
            {
                print_notification_transport_status(&path, Some(config))?;
                return Ok(());
            }
            let url = std::env::var("TRON_RELAY_URL").unwrap_or_default();
            let secret = std::env::var("TRON_RELAY_SECRET").unwrap_or_default();
            ensure!(
                !url.is_empty() && !secret.is_empty(),
                "TRON_RELAY_URL and TRON_RELAY_SECRET must both be present for legacy import"
            );
            let config = save_notification_relay_credentials(
                &path,
                NotificationRelayCredentials { url, secret },
            )
            .context("Failed to import notification relay credentials")?;
            print_notification_transport_status(&path, Some(config))?;
            eprintln!("Legacy development notification relay configuration imported.");
            Ok(())
        }
    }
}

pub(super) fn print_notification_transport_status(
    path: &Path,
    config: Option<crate::domains::auth::credentials::NotificationPushConfig>,
) -> Result<()> {
    use crate::domains::auth::credentials::{
        NotificationTransportMode, load_apple_push_credentials,
    };

    let direct_configured = load_apple_push_credentials(path)
        .context("Failed to load APNs credentials")?
        .is_some();
    let mode = config
        .as_ref()
        .map_or(NotificationTransportMode::Direct, |value| value.mode);
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "mode":mode.as_str(),
            "relayConfigured":config.as_ref().and_then(|value| value.relay.as_ref()).is_some(),
            "directConfigured":direct_configured,
            "configured":match mode {
                NotificationTransportMode::Relay => config
                    .as_ref()
                    .and_then(|value| value.relay.as_ref())
                    .is_some(),
                NotificationTransportMode::Direct => direct_configured,
            },
        }))
        .context("Failed to encode notification transport status")?
    );
    Ok(())
}

pub(super) fn apns_auth_cli(action: &ApnsAction) -> Result<()> {
    use crate::domains::auth::credentials::{
        ApplePushCredentials, clear_apple_push_credentials, load_apple_push_credentials,
        save_apple_push_credentials,
    };

    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    match action {
        ApnsAction::Configure {
            team_id,
            key_id,
            private_key_file,
        } => {
            let private_key = std::fs::read_to_string(private_key_file).with_context(|| {
                format!(
                    "Failed to read APNs private key at {}",
                    private_key_file.display()
                )
            })?;
            let credentials = ApplePushCredentials {
                team_id: team_id.trim().to_owned(),
                key_id: key_id.trim().to_owned(),
                private_key,
            };
            credentials.validate().map_err(anyhow::Error::msg)?;
            crate::domains::worker_kernel::validate_apns_private_key(&credentials.private_key)
                .map_err(anyhow::Error::msg)?;
            save_apple_push_credentials(&path, &credentials)
                .context("Failed to save APNs credentials")?;
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "configured":true,
                    "teamId":credentials.team_id,
                    "keyId":credentials.key_id,
                }))
                .context("Failed to encode APNs status")?
            );
            eprintln!("APNs provider-token credentials configured.");
            Ok(())
        }
        ApnsAction::Status => {
            let credentials =
                load_apple_push_credentials(&path).context("Failed to load APNs credentials")?;
            println!(
                "{}",
                serde_json::to_string_pretty(&match credentials {
                    Some(credentials) => serde_json::json!({
                        "configured":true,
                        "teamId":credentials.team_id,
                        "keyId":credentials.key_id,
                    }),
                    None => serde_json::json!({"configured":false}),
                })
                .context("Failed to encode APNs status")?
            );
            Ok(())
        }
        ApnsAction::Clear => {
            let changed =
                clear_apple_push_credentials(&path).context("Failed to clear APNs credentials")?;
            println!(
                "{}",
                serde_json::to_string_pretty(
                    &serde_json::json!({"configured":false,"changed":changed})
                )
                .context("Failed to encode APNs clear status")?
            );
            eprintln!("APNs provider-token credentials cleared.");
            Ok(())
        }
    }
}

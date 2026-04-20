-- v006: Per-token APNs bundle ID on device_tokens.
--
-- After the Xcode scheme split (com.tron.mobile vs com.tron.mobile.beta),
-- each device token is valid only against the bundle that issued it. The
-- relay sends this value as the APNs `apns-topic` header; without it,
-- Beta-issued sandbox tokens were rejected with DeviceTokenNotForTopic.
--
-- Nullable by design: rows registered before this migration have NULL,
-- and the send path falls through to the relay worker's default
-- (env.APNS_BUNDLE_ID). Auto-deactivation on DeviceTokenNotForTopic /
-- BadDeviceToken clears stale legacy rows naturally on the next send.

ALTER TABLE device_tokens ADD COLUMN bundle_id TEXT;

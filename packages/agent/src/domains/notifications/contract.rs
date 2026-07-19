//! Notification domain contract constants.

pub(crate) const WORKER: &str = "notifications";
pub(crate) const NOTIFICATION_LIFECYCLE_TOPIC: &str = "notifications.lifecycle";
pub(crate) const READ_SCOPE: &str = "notifications.read";
pub(crate) const WRITE_SCOPE: &str = "notifications.write";
pub(crate) const DEVICE_READ_SCOPE: &str = "device.read";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const NOTIFICATION_SCHEMA_VERSION: &str = "tron.notifications.notification.v1";
pub(crate) const DELIVERY_SCHEMA_VERSION: &str = "tron.notifications.delivery.v1";
pub(crate) const DEFAULT_EVENT_FAMILY: &str = "agent_attention";
pub(crate) const EVENT_FAMILIES: &[&str] = &[
    "approval",
    "question",
    "goal",
    "schedule",
    "web",
    "git",
    "job",
    "subagent",
    "memory",
    "system",
    DEFAULT_EVENT_FAMILY,
];

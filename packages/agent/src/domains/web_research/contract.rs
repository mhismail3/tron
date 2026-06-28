//! Web research domain contract constants.

pub(crate) const WORKER: &str = "web_research";
pub(crate) const WEB_RESEARCH_LIFECYCLE_TOPIC: &str = "web_research.lifecycle";
pub(crate) const READ_SCOPE: &str = "web_research.read";
pub(crate) const WRITE_SCOPE: &str = "web_research.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const WEB_RESEARCH_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::WEB_RESEARCH_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const WEB_RESEARCH_REVIEW_SCHEMA_VERSION: &str =
    crate::engine::WEB_RESEARCH_REVIEW_PAYLOAD_SCHEMA_VERSION;
pub(crate) const WEB_RESEARCH_SOURCE_SCHEMA_VERSION: &str =
    crate::engine::WEB_RESEARCH_SOURCE_PAYLOAD_SCHEMA_VERSION;

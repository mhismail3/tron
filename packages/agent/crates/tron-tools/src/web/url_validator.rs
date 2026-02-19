//! URL validation, blocked domains, and protocol upgrade.
//!
//! Validates URLs for safety (blocks private IPs, localhost, internal domains)
//! and auto-upgrades HTTP to HTTPS.

use regex::Regex;
use url::Url;

const MAX_URL_LENGTH: usize = 2000;

/// URL validation error codes.
#[derive(Debug, PartialEq, Eq)]
pub enum UrlError {
    /// URL is empty or invalid format.
    InvalidFormat(String),
    /// URL exceeds maximum length.
    TooLong,
    /// Protocol is not HTTP or HTTPS.
    InvalidProtocol(String),
    /// URL contains embedded credentials.
    CredentialsInUrl,
    /// URL points to a private/internal address.
    InternalAddress(String),
    /// Domain is in the blocked list.
    DomainBlocked(String),
    /// Domain is not in the allowed list.
    DomainNotAllowed(String),
}

impl std::fmt::Display for UrlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidFormat(msg) => write!(f, "Invalid URL: {msg}"),
            Self::TooLong => write!(
                f,
                "URL exceeds maximum length of {MAX_URL_LENGTH} characters"
            ),
            Self::InvalidProtocol(p) => {
                write!(f, "Invalid protocol: {p} (only http/https allowed)")
            }
            Self::CredentialsInUrl => write!(f, "URL must not contain credentials"),
            Self::InternalAddress(host) => write!(f, "Internal/private address blocked: {host}"),
            Self::DomainBlocked(d) => write!(f, "Domain blocked: {d}"),
            Self::DomainNotAllowed(d) => write!(f, "Domain not in allowed list: {d}"),
        }
    }
}

/// Configuration for URL validation.
#[derive(Default)]
pub struct UrlValidatorConfig {
    /// Only allow these domains (empty = allow all).
    pub allowed_domains: Vec<String>,
    /// Block these domains.
    pub blocked_domains: Vec<String>,
}

/// Validate and normalize a URL.
///
/// Returns the validated HTTPS URL string, or an error.
pub fn validate_url(raw_url: &str, config: &UrlValidatorConfig) -> Result<String, UrlError> {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return Err(UrlError::InvalidFormat("URL is empty".into()));
    }

    if trimmed.len() > MAX_URL_LENGTH {
        return Err(UrlError::TooLong);
    }

    let parsed = Url::parse(trimmed).map_err(|e| UrlError::InvalidFormat(e.to_string()))?;

    // Protocol check
    match parsed.scheme() {
        "http" | "https" => {}
        other => return Err(UrlError::InvalidProtocol(other.into())),
    }

    // Credentials check
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(UrlError::CredentialsInUrl);
    }

    // Host check
    let host = parsed
        .host_str()
        .ok_or_else(|| UrlError::InvalidFormat("no host in URL".into()))?;

    // Internal address check
    if is_internal_address(host) {
        return Err(UrlError::InternalAddress(host.into()));
    }

    // Domain filtering
    if !config.blocked_domains.is_empty() && domain_in_list(host, &config.blocked_domains) {
        return Err(UrlError::DomainBlocked(host.into()));
    }

    if !config.allowed_domains.is_empty() && !domain_in_list(host, &config.allowed_domains) {
        return Err(UrlError::DomainNotAllowed(host.into()));
    }

    // Auto-upgrade HTTP to HTTPS
    let mut result = parsed;
    if result.scheme() == "http" {
        let _ = result.set_scheme("https");
    }

    Ok(result.to_string())
}

/// Check if a hostname matches any domain in the list (subdomain-aware).
fn domain_in_list(host: &str, domains: &[String]) -> bool {
    let host_lower = host.to_lowercase();
    domains.iter().any(|d| {
        let d_lower = d.to_lowercase();
        host_lower == d_lower || host_lower.ends_with(&format!(".{d_lower}"))
    })
}

fn is_internal_address(host: &str) -> bool {
    let patterns = [
        r"^localhost$",
        r"^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$",
        r"^0\.0\.0\.0$",
        r"^10\.\d{1,3}\.\d{1,3}\.\d{1,3}$",
        r"^172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}$",
        r"^192\.168\.\d{1,3}\.\d{1,3}$",
        r"^\[?::1\]?$",
        r"\.local$",
        r"\.internal$",
    ];
    let host_lower = host.to_lowercase();
    patterns
        .iter()
        .any(|p| Regex::new(p).is_ok_and(|re| re.is_match(&host_lower)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_config() -> UrlValidatorConfig {
        UrlValidatorConfig::default()
    }

    #[test]
    fn valid_https_url() {
        let r = validate_url("https://example.com/page", &default_config());
        assert!(r.is_ok());
        assert!(r.unwrap().starts_with("https://"));
    }

    #[test]
    fn http_auto_upgraded_to_https() {
        let r = validate_url("http://example.com/page", &default_config()).unwrap();
        assert!(r.starts_with("https://"));
    }

    #[test]
    fn missing_protocol_returns_error() {
        let r = validate_url("example.com/page", &default_config());
        assert!(matches!(r, Err(UrlError::InvalidFormat(_))));
    }

    #[test]
    fn invalid_url_format() {
        let r = validate_url("not a url at all", &default_config());
        assert!(matches!(r, Err(UrlError::InvalidFormat(_))));
    }

    #[test]
    fn empty_url() {
        let r = validate_url("", &default_config());
        assert!(matches!(r, Err(UrlError::InvalidFormat(_))));
    }

    #[test]
    fn url_too_long() {
        let long = format!("https://example.com/{}", "a".repeat(2000));
        let r = validate_url(&long, &default_config());
        assert!(matches!(r, Err(UrlError::TooLong)));
    }

    #[test]
    fn blocked_localhost() {
        let r = validate_url("https://localhost/page", &default_config());
        assert!(matches!(r, Err(UrlError::InternalAddress(_))));
    }

    #[test]
    fn blocked_127_0_0_1() {
        let r = validate_url("https://127.0.0.1/page", &default_config());
        assert!(matches!(r, Err(UrlError::InternalAddress(_))));
    }

    #[test]
    fn blocked_private_192_168() {
        let r = validate_url("https://192.168.1.1/page", &default_config());
        assert!(matches!(r, Err(UrlError::InternalAddress(_))));
    }

    #[test]
    fn blocked_private_10_x() {
        let r = validate_url("https://10.0.0.1/page", &default_config());
        assert!(matches!(r, Err(UrlError::InternalAddress(_))));
    }

    #[test]
    fn allowed_domains_filter() {
        let config = UrlValidatorConfig {
            allowed_domains: vec!["example.com".into()],
            ..Default::default()
        };
        let r = validate_url("https://example.com/page", &config);
        assert!(r.is_ok());

        let r2 = validate_url("https://other.com/page", &config);
        assert!(matches!(r2, Err(UrlError::DomainNotAllowed(_))));
    }

    #[test]
    fn blocked_domains_filter() {
        let config = UrlValidatorConfig {
            blocked_domains: vec!["evil.com".into()],
            ..Default::default()
        };
        let r = validate_url("https://evil.com/page", &config);
        assert!(matches!(r, Err(UrlError::DomainBlocked(_))));

        let r2 = validate_url("https://good.com/page", &config);
        assert!(r2.is_ok());
    }
}

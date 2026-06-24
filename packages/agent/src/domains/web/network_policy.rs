//! URL and DNS authority checks for direct web fetch.

use std::error::Error;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use tokio::net::lookup_host;
use url::{Host, Url};

use crate::shared::server::errors::CapabilityError;

use super::Deps;

pub(super) struct ValidatedUrl {
    pub(super) url: Url,
}

pub(super) fn validate_url(value: &str) -> Result<ValidatedUrl, CapabilityError> {
    let url = Url::parse(value).map_err(|error| invalid(format!("malformed url: {error}")))?;
    validate_url_parts(&url)?;
    match url.scheme() {
        "https" => validate_host(&url)?,
        "http" => validate_http_loopback(&url)?,
        other => {
            return Err(invalid(format!(
                "unsupported URL scheme {other}; web_fetch supports https and test loopback http only"
            )));
        }
    }
    Ok(ValidatedUrl { url })
}

pub(super) fn validate_final_url(url: &Url) -> Result<(), CapabilityError> {
    match url.scheme() {
        "https" => validate_host(url),
        "http" => validate_http_loopback(url),
        other => Err(invalid(format!(
            "redirected to unsupported URL scheme {other}"
        ))),
    }
}

pub(super) fn validate_redirect_target(url: &Url, previous: &[Url]) -> Result<(), CapabilityError> {
    validate_url_parts(url)?;
    match url.scheme() {
        "https" => validate_host(url),
        "http" if is_same_origin_http_loopback_redirect(url, previous) => {
            validate_http_loopback(url)
        }
        "http" => Err(invalid(
            "web_fetch rejects redirects to local/internal HTTP targets",
        )),
        other => Err(invalid(format!(
            "redirected to unsupported URL scheme {other}"
        ))),
    }
}

fn validate_url_parts(url: &Url) -> Result<(), CapabilityError> {
    if !url.username().is_empty() || url.password().is_some() {
        return Err(invalid("web_fetch rejects credentials in URLs"));
    }
    if url.fragment().is_some() {
        return Err(invalid("web_fetch rejects URL fragments"));
    }
    Ok(())
}

fn validate_host(url: &Url) -> Result<(), CapabilityError> {
    let Some(host) = url.host() else {
        return Err(invalid("web_fetch requires a URL host"));
    };
    match host {
        Host::Domain(domain) => {
            let canonical = canonical_domain(domain)?;
            if canonical == "localhost" || canonical.ends_with(".localhost") {
                return Err(invalid(
                    "web_fetch rejects localhost except test loopback http",
                ));
            }
            if canonical == "local"
                || canonical.ends_with(".local")
                || canonical == "internal"
                || canonical.ends_with(".internal")
            {
                return Err(invalid("web_fetch rejects local/internal host names"));
            }
        }
        Host::Ipv4(addr) => validate_ip(IpAddr::V4(addr))?,
        Host::Ipv6(addr) => validate_ip(IpAddr::V6(addr))?,
    }
    Ok(())
}

fn validate_http_loopback(url: &Url) -> Result<(), CapabilityError> {
    let Some(host) = url.host() else {
        return Err(invalid("web_fetch requires a URL host"));
    };
    match host {
        Host::Ipv4(addr) if addr.is_loopback() => Ok(()),
        Host::Ipv6(addr) if addr.is_loopback() => Ok(()),
        _ => Err(invalid(
            "web_fetch supports http only for test loopback IP targets",
        )),
    }
}

fn is_same_origin_http_loopback_redirect(url: &Url, previous: &[Url]) -> bool {
    let Some(last) = previous.last() else {
        return false;
    };
    is_http_loopback_url(url) && is_http_loopback_url(last) && same_origin(url, last)
}

fn is_http_loopback_url(url: &Url) -> bool {
    url.scheme() == "http" && validate_http_loopback(url).is_ok()
}

fn same_origin(left: &Url, right: &Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

fn canonical_domain(domain: &str) -> Result<String, CapabilityError> {
    let canonical = domain.trim_end_matches('.').to_ascii_lowercase();
    if canonical.is_empty() {
        return Err(invalid("web_fetch requires a URL host"));
    }
    Ok(canonical)
}

fn validate_ip(ip: IpAddr) -> Result<(), CapabilityError> {
    if is_unsafe_ip(ip) {
        return Err(invalid("web_fetch rejects local/internal IP targets"));
    }
    Ok(())
}

fn is_unsafe_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(addr) => is_unsafe_ipv4(addr),
        IpAddr::V6(addr) => is_unsafe_ipv6(addr),
    }
}

fn is_unsafe_ipv4(addr: Ipv4Addr) -> bool {
    let octets = addr.octets();
    addr.is_private()
        || addr.is_loopback()
        || addr.is_link_local()
        || addr.is_unspecified()
        || addr.is_broadcast()
        || addr.is_multicast()
        || octets[0] == 0
        || (octets[0] == 100 && (64..=127).contains(&octets[1]))
        || (octets[0] == 198 && (18..=19).contains(&octets[1]))
        || matches!(
            octets,
            [192, 0, 0, _] | [192, 0, 2, _] | [198, 51, 100, _] | [203, 0, 113, _]
        )
}

fn is_unsafe_ipv6(addr: Ipv6Addr) -> bool {
    addr.to_ipv4_mapped().is_some_and(is_unsafe_ipv4)
        || addr.is_loopback()
        || addr.is_unspecified()
        || addr.is_multicast()
        || addr.is_unique_local()
        || addr.is_unicast_link_local()
        || is_site_local_ipv6(addr)
        || embedded_unsafe_ipv4(addr).is_some()
        || matches!(addr.segments(), [0x2001, 0x0db8, ..])
}

fn is_site_local_ipv6(addr: Ipv6Addr) -> bool {
    (addr.segments()[0] & 0xffc0) == 0xfec0
}

fn embedded_unsafe_ipv4(addr: Ipv6Addr) -> Option<Ipv4Addr> {
    ipv4_compatible_addr(addr)
        .or_else(|| ipv4_translated_addr(addr))
        .filter(|addr| is_unsafe_ipv4(*addr))
}

fn ipv4_compatible_addr(addr: Ipv6Addr) -> Option<Ipv4Addr> {
    let segments = addr.segments();
    matches!(segments, [0, 0, 0, 0, 0, 0, _, _]).then(|| ipv4_from_tail(segments))
}

fn ipv4_translated_addr(addr: Ipv6Addr) -> Option<Ipv4Addr> {
    let segments = addr.segments();
    matches!(segments, [0, 0, 0, 0, 0xffff, 0, _, _]).then(|| ipv4_from_tail(segments))
}

fn ipv4_from_tail(segments: [u16; 8]) -> Ipv4Addr {
    Ipv4Addr::new(
        (segments[6] >> 8) as u8,
        segments[6] as u8,
        (segments[7] >> 8) as u8,
        segments[7] as u8,
    )
}

#[derive(Debug)]
pub(super) struct SafeDnsResolver {
    #[cfg(test)]
    overrides: Option<std::sync::Arc<std::collections::HashMap<String, Vec<SocketAddr>>>>,
}

impl SafeDnsResolver {
    pub(super) fn from_deps(deps: &Deps) -> Self {
        #[cfg(not(test))]
        let _ = deps;
        Self {
            #[cfg(test)]
            overrides: deps.dns_overrides.clone(),
        }
    }
}

impl Resolve for SafeDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        #[cfg(test)]
        let overrides = self.overrides.clone();
        Box::pin(async move {
            #[cfg(test)]
            let canonical = canonical_domain_for_dns(&host)?;
            #[cfg(not(test))]
            canonical_domain_for_dns(&host)?;
            let addrs = {
                #[cfg(test)]
                {
                    if let Some(addrs) = overrides
                        .as_ref()
                        .and_then(|overrides| overrides.get(&canonical))
                    {
                        addrs.clone()
                    } else {
                        system_lookup_host(&host).await?
                    }
                }
                #[cfg(not(test))]
                {
                    system_lookup_host(&host).await?
                }
            };
            validate_resolved_addrs(&addrs)?;
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

type DnsError = Box<dyn Error + Send + Sync>;

async fn system_lookup_host(host: &str) -> Result<Vec<SocketAddr>, DnsError> {
    lookup_host((host, 0))
        .await
        .map_err(|error| -> DnsError { Box::new(error) })
        .map(|addrs| addrs.collect())
}

fn canonical_domain_for_dns(host: &str) -> Result<String, DnsError> {
    canonical_domain(host)
        .map_err(|_| dns_error("web_fetch rejects local/internal host names during DNS resolution"))
}

fn validate_resolved_addrs(addrs: &[SocketAddr]) -> Result<(), DnsError> {
    if addrs.is_empty() {
        return Err(dns_error("web_fetch DNS resolution returned no addresses"));
    }
    if addrs.iter().any(|addr| is_unsafe_ip(addr.ip())) {
        return Err(dns_error(
            "web_fetch rejects DNS results for local/internal IP targets",
        ));
    }
    Ok(())
}

fn dns_error(message: &'static str) -> DnsError {
    std::io::Error::new(std::io::ErrorKind::PermissionDenied, message).into()
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

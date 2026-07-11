use super::*;

#[tokio::test]
async fn web_fetch_rejects_canonical_localhost_alias_before_network_io() {
    let (port, accepts) = loopback_accept_probe().await;
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-localhost-dot", "declared").await;
    let error = fixture
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("https://localhost.:{port}/forbidden"),
            "idempotencyKey": "web-fetch-localhost-dot"
        }))
        .await;
    assert!(
        error.contains("localhost"),
        "canonical localhost alias should be rejected, got: {error}"
    );
    assert_eq!(
        accepts.await.expect("accept probe"),
        0,
        "canonical localhost alias must fail before opening a socket"
    );
}

#[tokio::test]
async fn web_fetch_rejects_hostname_resolving_to_internal_ip_before_network_io() {
    let (port, accepts) = loopback_accept_probe().await;
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-rebinding", "declared").await;
    let mut overrides = HashMap::new();
    overrides.insert(
        "rebind.test".to_owned(),
        vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)],
    );

    let error = fixture
        .invoke_direct_error_with_dns_overrides(
            json!({
                "operation": "web_fetch",
                "url": format!("https://rebind.test:{port}/forbidden"),
                "idempotencyKey": "web-fetch-rebinding-loopback"
            }),
            overrides,
        )
        .await;
    assert!(
        error.contains("connection failed"),
        "DNS rebinding target should fail closed through resolver, got: {error}"
    );
    assert_eq!(
        accepts.await.expect("accept probe"),
        0,
        "unsafe DNS result must be rejected before TCP connect"
    );

    let mut private_overrides = HashMap::new();
    private_overrides.insert(
        "private.test".to_owned(),
        vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 10)), 0)],
    );
    let private_error = fixture
        .invoke_direct_error_with_dns_overrides(
            json!({
                "operation": "web_fetch",
                "url": "https://private.test/forbidden",
                "idempotencyKey": "web-fetch-rebinding-private"
            }),
            private_overrides,
        )
        .await;
    assert!(
        private_error.contains("connection failed"),
        "private DNS result should fail closed through resolver, got: {private_error}"
    );
}

#[tokio::test]
async fn web_fetch_rejects_hostname_resolving_to_unsafe_ipv6_before_network_io() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-rebinding-v6", "declared").await;
    for (host, addr) in [
        (
            "site-local-v6.test",
            Ipv6Addr::new(0xfec0, 0, 0, 0, 0, 0, 0, 1),
        ),
        (
            "compatible-loopback-v6.test",
            Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0x7f00, 1),
        ),
        (
            "translated-loopback-v6.test",
            Ipv6Addr::new(0, 0, 0, 0, 0xffff, 0, 0x7f00, 1),
        ),
    ] {
        let mut overrides = HashMap::new();
        overrides.insert(host.to_owned(), vec![SocketAddr::new(IpAddr::V6(addr), 0)]);
        let error = fixture
            .invoke_direct_error_with_dns_overrides(
                json!({
                    "operation": "web_fetch",
                    "url": format!("https://{host}/forbidden"),
                    "idempotencyKey": format!("web-fetch-rebinding-v6-{host}")
                }),
                overrides,
            )
            .await;
        assert!(
            error.contains("connection failed"),
            "unsafe IPv6 DNS result for {host} should fail closed through resolver, got: {error}"
        );
    }
}

#[tokio::test]
async fn web_fetch_rejects_unsafe_ipv6_url_literals() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-ipv6-url-validation", "declared").await;
    for url in [
        "https://[fec0::1]/private",
        "https://[::7f00:1]/private",
        "https://[::ffff:0:7f00:1]/private",
    ] {
        let error = fixture
            .invoke_error(json!({
                "operation": "web_fetch",
                "url": url,
                "idempotencyKey": format!("web-fetch-ipv6-url-validation-{url}")
            }))
            .await;
        assert!(
            error.contains("local/internal IP"),
            "unsafe IPv6 literal {url} should be rejected by URL validation, got: {error}"
        );
    }
}

#[tokio::test]
async fn web_fetch_rejects_unsupported_or_unsafe_urls() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-url-validation", "declared").await;
    for (url, expected) in [
        ("ftp://example.com/file", "unsupported URL scheme"),
        ("https://user:pass@example.com/", "credentials"),
        ("http://example.com/insecure", "http only for test loopback"),
        ("https://10.0.0.1/private", "local/internal IP"),
        ("https://[fec0::1]/private", "local/internal IP"),
        ("https://[::7f00:1]/private", "local/internal IP"),
        ("https://localhost/private", "localhost"),
        ("https://localhost./private", "localhost"),
        ("http://localhost/test", "http only for test loopback IP"),
        ("not a url", "malformed url"),
    ] {
        let error = fixture
            .invoke_error(json!({
                "operation": "web_fetch",
                "url": url,
                "idempotencyKey": format!("web-fetch-url-validation-{url}")
            }))
            .await;
        assert!(
            error.contains(expected),
            "expected {expected:?} for {url}, got {error}"
        );
    }
    let overlong = format!("https://example.com/{}", "a".repeat(2_100));
    let error = fixture
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": overlong,
            "idempotencyKey": "web-fetch-url-validation-overlong"
        }))
        .await;
    assert!(error.contains("exceeds 2048 bytes"));
}

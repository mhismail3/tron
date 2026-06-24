use super::*;

#[tokio::test]
async fn web_fetch_extracts_html_readable_text_before_redaction() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/html"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            r#"
                    <!doctype html>
                    <html>
                      <head>
                        <title>Readable &amp; Useful</title>
                        <style>.secret { display: none }</style>
                      </head>
                      <body>
                        <nav>skip navigation</nav>
                        <main>
                          <h1>Alpha</h1>
                          <p>Beta token=super-secret-token</p>
                          <script>let ignored = "script text";</script>
                          <aside>skip related links</aside>
                          <p>Gamma&nbsp;Delta</p>
                        </main>
                      </body>
                    </html>
                    "#,
            "text/html; charset=utf-8",
        ))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-html-extract", "declared").await;
    let value = fixture
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/html", server.uri()),
            "idempotencyKey": "web-fetch-html-extract"
        }))
        .await;
    let resource_id = value["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("web source resource");
    let payload = current_payload(&inspection);
    assert_eq!(
        payload["textEvidence"]["extractionMode"],
        json!("html_readable_text")
    );
    assert_eq!(payload["textEvidence"]["title"], json!("Readable & Useful"));
    assert_eq!(
        payload["textEvidence"]["extractorId"],
        json!("tron.web.html_readable_text")
    );
    let preview = payload["textEvidence"]["preview"].as_str().unwrap();
    assert!(preview.contains("Alpha Beta token=<redacted-secret> Gamma Delta"));
    assert!(!preview.contains("script text"));
    assert!(!preview.contains("skip navigation"));
    assert!(!preview.contains("super-secret-token"));
    assert_eq!(payload["redaction"]["applied"], json!(true));
}

#[tokio::test]
async fn web_fetch_preserves_non_html_content_type_behavior_and_bounds() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/json"))
        .respond_with(
            ResponseTemplate::new(200).set_body_raw(r#"{"alpha":true}"#, "application/json"),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/xml"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_raw("<root><alpha>true</alpha></root>", "application/xml"),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/binary"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "application/octet-stream")
                .set_body_bytes(vec![0, 159, 146, 150, 255]),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/non-utf8"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/plain")
                .set_body_bytes(vec![b'a', 0xff, b'b']),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/malformed"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_raw("<main><p>Alpha<script>ignore</script><p>Beta", "text/html"),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/oversized"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(
            format!("<main>{}</main>", "alpha ".repeat(200)),
            "text/html",
        ))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-content-types", "declared").await;
    for (path, key, expected_mode, expected_preview, max_output) in [
        ("/json", "json", "plain_text", r#"{"alpha":true}"#, 100),
        (
            "/xml",
            "xml",
            "plain_text",
            "<root><alpha>true</alpha></root>",
            100,
        ),
        ("/binary", "binary", "binary_omitted", "", 100),
        ("/non-utf8", "non-utf8", "plain_text", "a\u{fffd}b", 100),
        (
            "/malformed",
            "malformed",
            "html_readable_text",
            "Alpha Beta",
            100,
        ),
        (
            "/oversized",
            "oversized",
            "html_readable_text",
            "alpha alph",
            10,
        ),
    ] {
        let value = fixture
            .invoke_ok(json!({
                "operation": "web_fetch",
                "url": format!("{}{}", server.uri(), path),
                "maxOutputBytes": max_output,
                "idempotencyKey": format!("web-fetch-content-types-{key}")
            }))
            .await;
        let resource_id = value["details"]["web"]["webSourceResourceId"]
            .as_str()
            .expect("resource id");
        let inspection = ctx
            .engine_host
            .inspect_resource(resource_id)
            .await
            .expect("inspect")
            .expect("web source resource");
        let payload = current_payload(&inspection);
        assert_eq!(
            payload["textEvidence"]["extractionMode"],
            json!(expected_mode),
            "mode for {path}"
        );
        assert_eq!(
            payload["textEvidence"]["preview"],
            json!(expected_preview),
            "preview for {path}"
        );
        if path == "/oversized" {
            assert_eq!(payload["textEvidence"]["outputTextTruncated"], json!(true));
            assert_eq!(
                payload["textEvidence"]["extractedTextTruncated"],
                json!(true)
            );
        }
        if path == "/binary" {
            assert_eq!(payload["textEvidence"]["binaryBodyOmitted"], json!(true));
        }
    }
}

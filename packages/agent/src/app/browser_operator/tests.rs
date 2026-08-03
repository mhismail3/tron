//! Browser native-host protocol, cancellation, and lifecycle tests.

use super::protocol::validate_navigation_url;
use super::*;

fn decode(value: Value) -> Result<BrowserClientRequest, serde_json::Error> {
    serde_json::from_value(value)
}

#[test]
fn closed_action_contract_rejects_script_and_cookie_fields() {
    for forbidden in [
        serde_json::json!({
            "requestId":"req-1",
            "timeoutMs":1000,
            "action":{"kind":"observe","tabId":7,"script":"document.cookie"}
        }),
        serde_json::json!({
            "requestId":"req-1",
            "timeoutMs":1000,
            "action":{"kind":"cookies","tabId":7}
        }),
        serde_json::json!({
            "requestId":"req-1",
            "timeoutMs":1000,
            "action":{"kind":"navigate","tabId":7,"url":"https://example.test","headers":{"authorization":"secret"}}
        }),
    ] {
        assert!(decode(forbidden).is_err());
    }
}

#[test]
fn request_validation_bounds_targets_text_scroll_and_timeouts() {
    let valid = decode(serde_json::json!({
        "requestId":"req-1",
        "timeoutMs":5000,
        "action":{
            "kind":"type",
            "tabId":7,
            "observationId":"obs-1",
            "elementRef":"element-2",
            "text":"hello",
            "replace":true
        }
    }))
    .unwrap();
    validate_request(&valid).unwrap();

    for invalid in [
        serde_json::json!({"requestId":"req-1","timeoutMs":499,"action":{"kind":"tabs"}}),
        serde_json::json!({"requestId":"req-1","timeoutMs":5000,"action":{"kind":"observe","tabId":0}}),
        serde_json::json!({"requestId":"req-1","timeoutMs":5000,"action":{"kind":"scroll","tabId":7,"deltaX":0,"deltaY":2001}}),
        serde_json::json!({"requestId":"req-1","timeoutMs":5000,"action":{"kind":"key","tabId":7,"key":"Enter","observationId":"obs-1"}}),
    ] {
        let invalid = decode(invalid).unwrap();
        assert!(validate_request(&invalid).is_err());
    }
}

#[test]
fn navigation_rejects_credentials_and_non_web_schemes() {
    for invalid in [
        "https://user:secret@example.test/path",
        "javascript:alert(1)",
        "file:///etc/passwd",
        "http://example.test",
    ] {
        assert!(validate_navigation_url(invalid).is_err(), "{invalid}");
    }
    validate_navigation_url("https://example.test/search?q=tron").unwrap();
    validate_navigation_url("http://127.0.0.1:3000/test").unwrap();
}

#[test]
fn response_errors_are_sanitized_and_large_results_fail_closed() {
    let response = bounded_native_response(
        "req-1",
        false,
        None,
        Some(format!("bad\u{0}{}", "x".repeat(700))),
    );
    assert_eq!(response["ok"], false);
    let reason = response["error"].as_str().unwrap();
    assert!(!reason.contains('\u{0}'));
    assert_eq!(reason.chars().count(), 512);

    let response = bounded_native_response(
        "req-2",
        true,
        Some(serde_json::json!({"screenshot":"x".repeat(MAX_NATIVE_RESPONSE_BYTES)})),
        None,
    );
    assert_eq!(response["error"], "browser_response_oversized");
}

#[tokio::test]
async fn broker_serializes_requests_and_correlates_native_responses() {
    let (request_tx, request_rx) = mpsc::channel(MAX_PENDING_REQUESTS);
    let (native_tx, native_rx) = mpsc::channel(8);
    let (outbound_tx, mut outbound_rx) = mpsc::channel(8);
    let broker = tokio::spawn(run_broker(request_rx, native_rx, outbound_tx));
    native_tx
        .send(NativeEvent::Message(NativeInbound::Ready {
            protocol_version: PROTOCOL_VERSION,
        }))
        .await
        .unwrap();

    let (first_tx, first_rx) = oneshot::channel();
    let (second_tx, second_rx) = oneshot::channel();
    for (request_id, response) in [("request-1", first_tx), ("request-2", second_tx)] {
        request_tx
            .send(AdmittedRequest {
                request: BrowserClientRequest {
                    request_id: request_id.to_owned(),
                    timeout_ms: 5_000,
                    action: BrowserAction::Tabs,
                },
                deadline: Instant::now() + Duration::from_secs(5),
                response,
            })
            .await
            .unwrap();
    }

    let first = outbound_rx.recv().await.unwrap();
    assert_eq!(first["requestId"], "request-1");
    assert!(outbound_rx.try_recv().is_err());
    native_tx
        .send(NativeEvent::Message(NativeInbound::Response {
            request_id: "request-1".to_owned(),
            ok: true,
            result: Some(serde_json::json!({"tabs":[]})),
            error: None,
        }))
        .await
        .unwrap();
    assert_eq!(first_rx.await.unwrap()["ok"], true);

    let second = outbound_rx.recv().await.unwrap();
    assert_eq!(second["requestId"], "request-2");
    native_tx
        .send(NativeEvent::Message(NativeInbound::Response {
            request_id: "request-2".to_owned(),
            ok: true,
            result: Some(serde_json::json!({"tabs":[]})),
            error: None,
        }))
        .await
        .unwrap();
    assert_eq!(second_rx.await.unwrap()["ok"], true);
    drop(request_tx);
    broker.await.unwrap().unwrap();
}

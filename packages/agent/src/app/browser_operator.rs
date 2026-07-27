//! Closed Chrome Native Messaging bridge for the Browser Operator worker.
//!
//! Chrome owns the native-host process lifetime. The host exposes one
//! owner-only Unix socket under Tron Home so the ordinary Browser Operator
//! worker can submit a bounded action through its existing process primitive.
//! This module validates transport and actuator shape only: it does not plan
//! browser work, interpret pages, choose elements, or decide whether an
//! externally consequential action is appropriate.
//!
//! ## Core delta
//!
//! A normal worker process cannot attach to the user's existing Chrome session,
//! retain Chrome's user-granted `activeTab` permission, or use Native Messaging.
//! The fixed seam therefore admits exactly tab discovery, observation,
//! screenshot, click, type, fixed-key, scroll, and navigation requests. Chrome
//! enforces foreground consent and observe-after-act; the worker owns every
//! semantic decision. Owner-only socket permissions, typed validation, bounded
//! messages, one-at-a-time actuation, deadlines, and cancellation close the
//! host boundary without creating another job or state system. The extension
//! retains cancellation only for its bounded set of admitted request IDs,
//! expires it beyond the host deadline, and deletes request/listener state on
//! completion so late cancellation cannot become unbounded client state.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

const PROTOCOL_VERSION: u8 = 1;
const MAX_CLIENT_REQUEST_BYTES: usize = 16 * 1024;
const MAX_NATIVE_REQUEST_BYTES: usize = 64 * 1024;
const MAX_NATIVE_RESPONSE_BYTES: usize = 5 * 1_048_576;
const MAX_PENDING_REQUESTS: usize = 8;
const MIN_TIMEOUT_MS: u64 = 500;
const MAX_TIMEOUT_MS: u64 = 20_000;

/// Closed request accepted from the ordinary Browser Operator worker.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BrowserClientRequest {
    request_id: String,
    timeout_ms: u64,
    action: BrowserAction,
}

/// Fixed browser actuator vocabulary. No script, cookie, credential, download,
/// extension API, arbitrary header, or shell field is representable.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum BrowserAction {
    Tabs,
    Observe {
        tab_id: i64,
    },
    Screenshot {
        tab_id: i64,
    },
    Click {
        tab_id: i64,
        observation_id: String,
        element_ref: String,
    },
    Type {
        tab_id: i64,
        observation_id: String,
        element_ref: String,
        text: String,
        #[serde(default)]
        replace: bool,
    },
    Key {
        tab_id: i64,
        key: BrowserKey,
        #[serde(skip_serializing_if = "Option::is_none")]
        observation_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        element_ref: Option<String>,
    },
    Scroll {
        tab_id: i64,
        delta_x: i32,
        delta_y: i32,
    },
    Navigate {
        tab_id: i64,
        url: String,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
enum BrowserKey {
    Enter,
    Tab,
    Escape,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    PageUp,
    PageDown,
    Home,
    End,
    Backspace,
    Delete,
    Space,
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum NativeInbound {
    Ready {
        protocol_version: u8,
    },
    Response {
        request_id: String,
        ok: bool,
        result: Option<Value>,
        error: Option<String>,
    },
}

#[derive(Debug)]
enum NativeEvent {
    Message(NativeInbound),
    Disconnected(String),
}

#[derive(Debug)]
struct AdmittedRequest {
    request: BrowserClientRequest,
    deadline: Instant,
    response: oneshot::Sender<Value>,
}

#[derive(Debug)]
struct ActiveRequest {
    request_id: String,
    deadline: Instant,
    response: oneshot::Sender<Value>,
}

#[derive(Serialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
enum NativeOutbound<'a> {
    Request {
        protocol_version: u8,
        request_id: &'a str,
        action: &'a BrowserAction,
    },
    Cancel {
        protocol_version: u8,
        request_id: &'a str,
    },
}

/// Run the Chrome-owned native host until the extension disconnects.
#[cfg(unix)]
pub(crate) async fn run_native_host(socket_path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    use tokio::net::UnixListener;

    let parent = socket_path
        .parent()
        .context("browser native-host socket has no parent directory")?;
    std::fs::create_dir_all(parent).with_context(|| {
        format!(
            "create browser native-host socket directory {}",
            parent.display()
        )
    })?;
    std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
        .context("secure browser native-host socket directory")?;
    remove_stale_socket(socket_path)?;
    let listener = UnixListener::bind(socket_path)
        .with_context(|| format!("bind browser native-host socket {}", socket_path.display()))?;
    std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))
        .context("secure browser native-host socket")?;
    let _socket_guard = SocketCleanup(socket_path.to_path_buf());

    let (native_tx, native_rx) = mpsc::channel::<NativeEvent>(32);
    let (outbound_tx, outbound_rx) = mpsc::channel::<Value>(32);
    let (request_tx, request_rx) = mpsc::channel::<AdmittedRequest>(MAX_PENDING_REQUESTS);
    let stdin_thread = spawn_native_stdin(native_tx);
    let stdout_thread = spawn_native_stdout(outbound_rx);
    let mut broker = tokio::spawn(run_broker(request_rx, native_rx, outbound_tx));
    let mut clients = tokio::task::JoinSet::new();

    let broker_outcome = loop {
        tokio::select! {
            broker_result = &mut broker => {
                break broker_result
                    .context("join browser native-host broker")
                    .and_then(|result| result);
            }
            accepted = listener.accept() => {
                let (stream, _) = match accepted {
                    Ok(accepted) => accepted,
                    Err(error) => {
                        broker.abort();
                        break Err(error).context("accept browser native-host client");
                    }
                };
                let sender = request_tx.clone();
                clients.spawn(async move {
                    let _ = handle_client(stream, sender).await;
                });
            }
        }
    };
    drop(request_tx);
    clients.abort_all();
    while clients.join_next().await.is_some() {}
    if broker_outcome.is_ok() {
        let _ = stdin_thread.join();
        let _ = stdout_thread.join();
    }
    broker_outcome
}

/// Chrome Native Messaging is a macOS/Linux boundary in this release.
#[cfg(not(unix))]
pub(crate) async fn run_native_host(_socket_path: &Path) -> Result<()> {
    bail!("the Browser Operator native host currently requires Unix sockets")
}

#[cfg(unix)]
fn remove_stale_socket(socket_path: &Path) -> Result<()> {
    use std::os::unix::fs::FileTypeExt as _;
    use std::os::unix::net::UnixStream;

    if !socket_path.exists() {
        return Ok(());
    }
    if UnixStream::connect(socket_path).is_ok() {
        bail!(
            "a Browser Operator native host is already active at {}",
            socket_path.display()
        );
    }
    let metadata = std::fs::symlink_metadata(socket_path)
        .with_context(|| format!("inspect stale browser socket {}", socket_path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_socket() {
        bail!(
            "refusing to replace non-socket Browser Operator path {}",
            socket_path.display()
        );
    }
    std::fs::remove_file(socket_path)
        .with_context(|| format!("remove stale browser socket {}", socket_path.display()))
}

#[cfg(unix)]
async fn handle_client(
    mut stream: tokio::net::UnixStream,
    sender: mpsc::Sender<AdmittedRequest>,
) -> Result<()> {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

    let mut bytes = Vec::new();
    let read = tokio::time::timeout(
        Duration::from_secs(2),
        (&mut stream)
            .take((MAX_CLIENT_REQUEST_BYTES + 1) as u64)
            .read_to_end(&mut bytes),
    )
    .await
    .context("browser client request timed out")?
    .context("read browser client request")?;
    if read == 0 || bytes.len() > MAX_CLIENT_REQUEST_BYTES {
        bail!("browser client request is empty or oversized");
    }
    let request: BrowserClientRequest =
        serde_json::from_slice(&bytes).context("decode browser client request")?;
    validate_request(&request)?;
    let timeout = Duration::from_millis(request.timeout_ms);
    let (response_tx, response_rx) = oneshot::channel();
    sender
        .send(AdmittedRequest {
            request,
            deadline: Instant::now() + timeout,
            response: response_tx,
        })
        .await
        .context("Browser Operator native host is unavailable")?;
    let response = tokio::time::timeout(timeout + Duration::from_millis(250), response_rx)
        .await
        .context("Browser Operator request timed out")?
        .context("Browser Operator request was cancelled")?;
    let encoded = serde_json::to_vec(&response).context("encode Browser Operator response")?;
    if encoded.len() > MAX_NATIVE_RESPONSE_BYTES {
        bail!("Browser Operator response exceeded its size ceiling");
    }
    stream
        .write_all(&encoded)
        .await
        .context("write Browser Operator response")?;
    stream
        .shutdown()
        .await
        .context("close Browser Operator response")
}

async fn run_broker(
    mut request_rx: mpsc::Receiver<AdmittedRequest>,
    mut native_rx: mpsc::Receiver<NativeEvent>,
    outbound_tx: mpsc::Sender<Value>,
) -> Result<()> {
    let mut ready = false;
    let mut queue = VecDeque::<AdmittedRequest>::new();
    let mut active: Option<ActiveRequest> = None;
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            request = request_rx.recv() => {
                let Some(request) = request else {
                    fail_all(&mut active, &mut queue, "browser_host_stopped");
                    return Ok(());
                };
                if queue.len() + usize::from(active.is_some()) >= MAX_PENDING_REQUESTS {
                    let _ = request.response.send(error_response(
                        &request.request.request_id,
                        "browser_host_busy",
                    ));
                } else {
                    queue.push_back(request);
                }
            }
            event = native_rx.recv() => {
                match event {
                    Some(NativeEvent::Message(NativeInbound::Ready { protocol_version })) => {
                        if protocol_version != PROTOCOL_VERSION {
                            fail_all(&mut active, &mut queue, "protocol_version_mismatch");
                            bail!("Chrome extension uses an unsupported Browser Operator protocol");
                        }
                        ready = true;
                    }
                    Some(NativeEvent::Message(NativeInbound::Response {
                        request_id,
                        ok,
                        result,
                        error,
                    })) => {
                        let Some(current) = active.take() else {
                            continue;
                        };
                        if current.request_id != request_id {
                            let _ = current.response.send(error_response(
                                &current.request_id,
                                "response_identity_mismatch",
                            ));
                            fail_all(&mut active, &mut queue, "response_identity_mismatch");
                            bail!("Chrome extension returned a mismatched Browser Operator request id");
                        }
                        let response = bounded_native_response(&request_id, ok, result, error);
                        let _ = current.response.send(response);
                    }
                    Some(NativeEvent::Disconnected(reason)) => {
                        fail_all(&mut active, &mut queue, "chrome_extension_disconnected");
                        bail!("Chrome extension disconnected: {reason}");
                    }
                    None => {
                        fail_all(&mut active, &mut queue, "chrome_extension_disconnected");
                        return Ok(());
                    }
                }
            }
            _ = tick.tick() => {
                let now = Instant::now();
                while queue.front().is_some_and(|item| item.deadline <= now) {
                    if let Some(expired) = queue.pop_front() {
                        let _ = expired.response.send(error_response(
                            &expired.request.request_id,
                            "browser_request_timed_out",
                        ));
                    }
                }
                let should_cancel = active.as_ref().is_some_and(|current| {
                    current.deadline <= now || current.response.is_closed()
                });
                if should_cancel && let Some(cancelled) = active.take() {
                    let message = serde_json::to_value(NativeOutbound::Cancel {
                        protocol_version: PROTOCOL_VERSION,
                        request_id: &cancelled.request_id,
                    })
                    .context("encode Browser Operator cancellation")?;
                    let _ = outbound_tx.send(message).await;
                    let _ = cancelled.response.send(error_response(
                        &cancelled.request_id,
                        "browser_request_cancelled",
                    ));
                }
            }
        }
        if ready && active.is_none() {
            while let Some(next) = queue.pop_front() {
                if next.deadline <= Instant::now() || next.response.is_closed() {
                    let _ = next.response.send(error_response(
                        &next.request.request_id,
                        "browser_request_cancelled",
                    ));
                    continue;
                }
                let message = serde_json::to_value(NativeOutbound::Request {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: &next.request.request_id,
                    action: &next.request.action,
                })
                .context("encode Browser Operator request")?;
                let encoded_len = serde_json::to_vec(&message)
                    .context("measure Browser Operator request")?
                    .len();
                if encoded_len > MAX_NATIVE_REQUEST_BYTES {
                    let _ = next.response.send(error_response(
                        &next.request.request_id,
                        "browser_request_oversized",
                    ));
                    continue;
                }
                outbound_tx
                    .send(message)
                    .await
                    .context("Chrome extension response channel closed")?;
                active = Some(ActiveRequest {
                    request_id: next.request.request_id,
                    deadline: next.deadline,
                    response: next.response,
                });
                break;
            }
        }
    }
}

fn fail_all(
    active: &mut Option<ActiveRequest>,
    queue: &mut VecDeque<AdmittedRequest>,
    reason: &str,
) {
    if let Some(active) = active.take() {
        let _ = active
            .response
            .send(error_response(&active.request_id, reason));
    }
    for queued in queue.drain(..) {
        let _ = queued
            .response
            .send(error_response(&queued.request.request_id, reason));
    }
}

fn validate_request(request: &BrowserClientRequest) -> Result<()> {
    validate_identifier("requestId", &request.request_id, 128)?;
    if !(MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&request.timeout_ms) {
        bail!("timeoutMs must be between {MIN_TIMEOUT_MS} and {MAX_TIMEOUT_MS}");
    }
    match &request.action {
        BrowserAction::Tabs => {}
        BrowserAction::Observe { tab_id } | BrowserAction::Screenshot { tab_id } => {
            validate_tab_id(*tab_id)?;
        }
        BrowserAction::Click {
            tab_id,
            observation_id,
            element_ref,
        } => {
            validate_element_target(*tab_id, observation_id, element_ref)?;
        }
        BrowserAction::Type {
            tab_id,
            observation_id,
            element_ref,
            text,
            ..
        } => {
            validate_element_target(*tab_id, observation_id, element_ref)?;
            if text.len() > 4_000 {
                bail!("typed text exceeds the 4000-byte ceiling");
            }
        }
        BrowserAction::Key {
            tab_id,
            observation_id,
            element_ref,
            ..
        } => {
            validate_tab_id(*tab_id)?;
            if observation_id.is_some() != element_ref.is_some() {
                bail!("key target requires both observationId and elementRef");
            }
            if let (Some(observation_id), Some(element_ref)) = (observation_id, element_ref) {
                validate_element_target(*tab_id, observation_id, element_ref)?;
            }
        }
        BrowserAction::Scroll {
            tab_id,
            delta_x,
            delta_y,
        } => {
            validate_tab_id(*tab_id)?;
            if *delta_x == 0 && *delta_y == 0 {
                bail!("scroll delta must not be zero");
            }
            if delta_x.unsigned_abs() > 2_000 || delta_y.unsigned_abs() > 2_000 {
                bail!("scroll deltas must be within -2000...2000");
            }
        }
        BrowserAction::Navigate { tab_id, url } => {
            validate_tab_id(*tab_id)?;
            validate_navigation_url(url)?;
        }
    }
    Ok(())
}

fn validate_tab_id(tab_id: i64) -> Result<()> {
    if tab_id <= 0 {
        bail!("tabId must be a positive stable Chrome tab id");
    }
    Ok(())
}

fn validate_element_target(tab_id: i64, observation_id: &str, element_ref: &str) -> Result<()> {
    validate_tab_id(tab_id)?;
    validate_identifier("observationId", observation_id, 96)?;
    validate_identifier("elementRef", element_ref, 128)
}

fn validate_identifier(name: &str, value: &str, max_bytes: usize) -> Result<()> {
    if value.is_empty()
        || value.len() > max_bytes
        || value
            .bytes()
            .any(|byte| !(byte.is_ascii_alphanumeric() || b"-_:.".contains(&byte)))
    {
        bail!("{name} must be a 1..={max_bytes}-byte identifier");
    }
    Ok(())
}

fn validate_navigation_url(raw: &str) -> Result<()> {
    if raw.len() > 2_048 {
        bail!("navigation URL exceeds the 2048-byte ceiling");
    }
    let parsed = url::Url::parse(raw).context("navigation URL must be absolute")?;
    if !parsed.username().is_empty() || parsed.password().is_some() {
        bail!("navigation URL must not contain credentials");
    }
    let is_loopback_http = parsed.scheme() == "http"
        && parsed
            .host_str()
            .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]"));
    if parsed.scheme() != "https" && !is_loopback_http {
        bail!("navigation allows HTTPS or loopback HTTP only");
    }
    Ok(())
}

fn bounded_native_response(
    request_id: &str,
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
) -> Value {
    let response = if ok {
        serde_json::json!({
            "requestId": request_id,
            "ok": true,
            "result": result.unwrap_or(Value::Null),
        })
    } else {
        let reason = error
            .as_deref()
            .map(sanitize_reason)
            .filter(|reason| !reason.is_empty())
            .unwrap_or_else(|| "browser_action_failed".to_owned());
        error_response(request_id, &reason)
    };
    if serde_json::to_vec(&response).map_or(true, |bytes| bytes.len() > MAX_NATIVE_RESPONSE_BYTES) {
        error_response(request_id, "browser_response_oversized")
    } else {
        response
    }
}

fn error_response(request_id: &str, reason: &str) -> Value {
    serde_json::json!({
        "requestId": request_id,
        "ok": false,
        "error": sanitize_reason(reason),
    })
}

fn sanitize_reason(reason: &str) -> String {
    reason
        .chars()
        .filter(|character| !character.is_control() || matches!(character, '\n' | '\r' | '\t'))
        .take(512)
        .collect()
}

fn spawn_native_stdin(sender: mpsc::Sender<NativeEvent>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        loop {
            let mut length = [0_u8; 4];
            if let Err(error) = stdin.read_exact(&mut length) {
                let _ = sender.blocking_send(NativeEvent::Disconnected(error.to_string()));
                break;
            }
            let length = u32::from_le_bytes(length) as usize;
            if length == 0 || length > MAX_NATIVE_RESPONSE_BYTES {
                let _ = sender.blocking_send(NativeEvent::Disconnected(
                    "native message is empty or oversized".to_owned(),
                ));
                break;
            }
            let mut bytes = vec![0_u8; length];
            if let Err(error) = stdin.read_exact(&mut bytes) {
                let _ = sender.blocking_send(NativeEvent::Disconnected(error.to_string()));
                break;
            }
            match serde_json::from_slice::<NativeInbound>(&bytes) {
                Ok(message) => {
                    if sender.blocking_send(NativeEvent::Message(message)).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = sender.blocking_send(NativeEvent::Disconnected(format!(
                        "invalid native message: {error}"
                    )));
                    break;
                }
            }
        }
    })
}

fn spawn_native_stdout(mut receiver: mpsc::Receiver<Value>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut stdout = io::stdout().lock();
        while let Some(message) = receiver.blocking_recv() {
            let Ok(bytes) = serde_json::to_vec(&message) else {
                break;
            };
            let Ok(length) = u32::try_from(bytes.len()) else {
                break;
            };
            if bytes.len() > MAX_NATIVE_REQUEST_BYTES
                || stdout.write_all(&length.to_le_bytes()).is_err()
                || stdout.write_all(&bytes).is_err()
                || stdout.flush().is_err()
            {
                break;
            }
        }
    })
}

struct SocketCleanup(PathBuf);

impl Drop for SocketCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
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
}

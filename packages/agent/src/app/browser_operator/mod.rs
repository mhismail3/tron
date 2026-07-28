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
//! `protocol` owns closed request validation plus bounded/redacted responses;
//! `lifecycle` owns native stdio threads and Unix-socket cleanup. This entry
//! point remains the one serialized request and socket owner.

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

mod lifecycle;
mod protocol;

use lifecycle::{SocketCleanup, spawn_native_stdin, spawn_native_stdout};
use protocol::{bounded_native_response, error_response, validate_request};

#[cfg(test)]
mod tests;

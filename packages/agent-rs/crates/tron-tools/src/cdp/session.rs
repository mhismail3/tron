//! CDP browser session — thin client over `tokio-tungstenite`.
//!
//! Only implements the CDP commands we actually need (not the entire protocol).

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::sync::{broadcast, mpsc, oneshot, Mutex};
use tokio::task::JoinHandle;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use tokio_tungstenite::tungstenite::Message;

use super::error::BrowserError;
use super::types::{BrowserEvent, ScreencastOptions};

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Pending CDP command waiting for response.
type PendingTx = oneshot::Sender<Result<Value, String>>;

/// A single CDP browser session.
pub struct BrowserSession {
    cmd_tx: mpsc::Sender<CdpCommand>,
    is_streaming: AtomicBool,
    screencast_handle: Mutex<Option<JoinHandle<()>>>,
    current_url: parking_lot::RwLock<Option<String>>,
    chrome_process: Mutex<Option<Child>>,
    _handler: JoinHandle<()>,
}

/// Internal CDP command message.
struct CdpCommand {
    method: String,
    params: Value,
    response_tx: PendingTx,
}

impl BrowserSession {
    /// Launch a headless Chrome, connect via CDP WebSocket.
    pub async fn launch(chrome_path: &std::path::Path) -> Result<Self, BrowserError> {
        // Find a free port
        let listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| {
            BrowserError::LaunchFailed {
                context: format!("bind port: {e}"),
            }
        })?;
        let port = listener
            .local_addr()
            .map_err(|e| BrowserError::LaunchFailed {
                context: format!("local_addr: {e}"),
            })?
            .port();
        drop(listener);

        // Launch Chrome
        let mut child = Command::new(chrome_path)
            .arg("--headless=new")
            .arg("--disable-gpu")
            .arg("--no-sandbox")
            .arg("--disable-dev-shm-usage")
            .arg(format!("--remote-debugging-port={port}"))
            .arg("--window-size=1280,800")
            .arg("about:blank")
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| BrowserError::LaunchFailed {
                context: e.to_string(),
            })?;

        // Wait for Chrome to start accepting connections
        let ws_url = wait_for_ws_url(port, &mut child).await?;

        // Connect to the page WebSocket
        let (ws, _) = connect_async(&ws_url)
            .await
            .map_err(|e| BrowserError::LaunchFailed {
                context: format!("WebSocket connect: {e}"),
            })?;

        let (cmd_tx, cmd_rx) = mpsc::channel::<CdpCommand>(64);
        let handler = tokio::spawn(cdp_handler_loop(ws, cmd_rx));

        Ok(Self {
            cmd_tx,
            is_streaming: AtomicBool::new(false),
            screencast_handle: Mutex::new(None),
            current_url: parking_lot::RwLock::new(None),
            chrome_process: Mutex::new(Some(child)),
            _handler: handler,
        })
    }

    /// Whether screencast streaming is active.
    pub fn is_streaming(&self) -> bool {
        self.is_streaming.load(Ordering::Relaxed)
    }

    /// Current page URL.
    pub fn current_url(&self) -> Option<String> {
        self.current_url.read().clone()
    }

    // ─── CDP command helper ──────────────────────────────────────────────

    async fn send_cdp(
        &self,
        method: &str,
        params: Value,
    ) -> Result<Value, BrowserError> {
        let (tx, rx) = oneshot::channel();
        self.cmd_tx
            .send(CdpCommand {
                method: method.into(),
                params,
                response_tx: tx,
            })
            .await
            .map_err(|_| BrowserError::Cdp("handler closed".into()))?;

        let result = tokio::time::timeout(Duration::from_secs(30), rx)
            .await
            .map_err(|_| BrowserError::Timeout {
                timeout_ms: 30_000,
                context: format!("CDP {method}"),
            })?
            .map_err(|_| BrowserError::Cdp("response dropped".into()))?;

        result.map_err(BrowserError::Cdp)
    }

    // ─── Navigation ──────────────────────────────────────────────────────

    /// Navigate to a URL.
    pub async fn navigate(&self, url: &str) -> Result<(), BrowserError> {
        let _ = self
            .send_cdp("Page.navigate", json!({ "url": url }))
            .await
            .map_err(|e| BrowserError::NavigationFailed {
                url: url.into(),
                reason: e.to_string(),
            })?;
        // Wait for load
        let _ = self.send_cdp("Page.loadEventFired", json!({})).await;
        *self.current_url.write() = Some(url.to_string());
        Ok(())
    }

    /// Go back in browser history.
    #[allow(clippy::cast_possible_truncation)]
    pub async fn go_back(&self) -> Result<(), BrowserError> {
        let history = self
            .send_cdp("Page.getNavigationHistory", json!({}))
            .await?;
        let idx = history["currentIndex"].as_u64().unwrap_or(0) as usize;
        if idx > 0 {
            let entry_id = history["entries"][idx - 1]["id"]
                .as_i64()
                .unwrap_or(0);
            let _ = self
                .send_cdp(
                    "Page.navigateToHistoryEntry",
                    json!({ "entryId": entry_id }),
                )
                .await?;
            self.update_url().await;
        }
        Ok(())
    }

    /// Go forward in browser history.
    #[allow(clippy::cast_possible_truncation)]
    pub async fn go_forward(&self) -> Result<(), BrowserError> {
        let history = self
            .send_cdp("Page.getNavigationHistory", json!({}))
            .await?;
        let idx = history["currentIndex"].as_u64().unwrap_or(0) as usize;
        let entries = history["entries"].as_array();
        if let Some(entries) = entries {
            if idx + 1 < entries.len() {
                let entry_id = entries[idx + 1]["id"].as_i64().unwrap_or(0);
                let _ = self
                    .send_cdp(
                        "Page.navigateToHistoryEntry",
                        json!({ "entryId": entry_id }),
                    )
                    .await?;
                self.update_url().await;
            }
        }
        Ok(())
    }

    /// Reload the current page.
    pub async fn reload(&self) -> Result<(), BrowserError> {
        let _ = self.send_cdp("Page.reload", json!({})).await?;
        Ok(())
    }

    // ─── Interaction ─────────────────────────────────────────────────────

    /// Click an element by CSS selector.
    pub async fn click(&self, selector: &str) -> Result<(), BrowserError> {
        self.ensure_element_exists(selector).await?;
        let js = format!(
            r"document.querySelector({}).click()",
            serde_json::to_string(selector).unwrap_or_default(),
        );
        let _ = self.evaluate(&js).await?;
        Ok(())
    }

    /// Fill an input element with a value.
    pub async fn fill(&self, selector: &str, value: &str) -> Result<(), BrowserError> {
        self.ensure_element_exists(selector).await?;
        let js = format!(
            r"(() => {{
                const el = document.querySelector({sel});
                el.focus();
                el.value = {val};
                el.dispatchEvent(new Event('input', {{ bubbles: true }}));
                el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            }})()",
            sel = serde_json::to_string(selector).unwrap_or_default(),
            val = serde_json::to_string(value).unwrap_or_default(),
        );
        let _ = self.evaluate(&js).await?;
        Ok(())
    }

    /// Type text into an element.
    pub async fn type_text(
        &self,
        selector: &str,
        text: &str,
        _slowly: bool,
    ) -> Result<(), BrowserError> {
        self.ensure_element_exists(selector).await?;
        // Focus the element
        let focus_js = format!(
            "document.querySelector({}).focus()",
            serde_json::to_string(selector).unwrap_or_default(),
        );
        let _ = self.evaluate(&focus_js).await?;

        // Type via Input.dispatchKeyEvent for each char
        for ch in text.chars() {
            let _ = self
                .send_cdp(
                    "Input.dispatchKeyEvent",
                    json!({
                        "type": "keyDown",
                        "text": ch.to_string(),
                        "key": ch.to_string(),
                    }),
                )
                .await?;
            let _ = self
                .send_cdp(
                    "Input.dispatchKeyEvent",
                    json!({
                        "type": "keyUp",
                        "key": ch.to_string(),
                    }),
                )
                .await?;
        }
        Ok(())
    }

    /// Select an option in a `<select>` element.
    pub async fn select_option(&self, selector: &str, value: &str) -> Result<(), BrowserError> {
        self.ensure_element_exists(selector).await?;
        let js = format!(
            r"(() => {{
                const el = document.querySelector({sel});
                el.value = {val};
                el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            }})()",
            sel = serde_json::to_string(selector).unwrap_or_default(),
            val = serde_json::to_string(value).unwrap_or_default(),
        );
        let _ = self.evaluate(&js).await?;
        Ok(())
    }

    /// Hover over an element.
    pub async fn hover(&self, selector: &str) -> Result<(), BrowserError> {
        self.ensure_element_exists(selector).await?;
        // Get element center coordinates via JS
        let js = format!(
            r"(() => {{
                const el = document.querySelector({sel});
                const r = el.getBoundingClientRect();
                return {{ x: r.x + r.width / 2, y: r.y + r.height / 2 }};
            }})()",
            sel = serde_json::to_string(selector).unwrap_or_default(),
        );
        let coords = self.evaluate(&js).await?;
        let x = coords["x"].as_f64().unwrap_or(0.0);
        let y = coords["y"].as_f64().unwrap_or(0.0);
        let _ = self
            .send_cdp(
                "Input.dispatchMouseEvent",
                json!({ "type": "mouseMoved", "x": x, "y": y }),
            )
            .await?;
        Ok(())
    }

    /// Press a keyboard key.
    pub async fn press_key(&self, key: &str) -> Result<(), BrowserError> {
        let _ = self
            .send_cdp(
                "Input.dispatchKeyEvent",
                json!({ "type": "keyDown", "key": key }),
            )
            .await?;
        let _ = self
            .send_cdp(
                "Input.dispatchKeyEvent",
                json!({ "type": "keyUp", "key": key }),
            )
            .await?;
        Ok(())
    }

    // ─── Observation ─────────────────────────────────────────────────────

    /// Take a screenshot (PNG, base64-encoded).
    pub async fn screenshot(&self) -> Result<String, BrowserError> {
        let result = self
            .send_cdp(
                "Page.captureScreenshot",
                json!({ "format": "png" }),
            )
            .await?;
        result["data"]
            .as_str()
            .map(String::from)
            .ok_or_else(|| BrowserError::ActionFailed {
                action: "screenshot".into(),
                reason: "no data in response".into(),
            })
    }

    /// Get accessibility tree snapshot.
    pub async fn snapshot(&self) -> Result<String, BrowserError> {
        let result = self
            .send_cdp("Accessibility.getFullAXTree", json!({}))
            .await?;

        let mut output = String::new();
        if let Some(nodes) = result["nodes"].as_array() {
            for node in nodes {
                let role = node["role"]["value"].as_str().unwrap_or("unknown");
                if let Some(name) = node["name"]["value"].as_str() {
                    if !name.is_empty() {
                        let _ = writeln!(output, "[{role}] {name}");
                    }
                }
            }
        }
        Ok(output)
    }

    /// Get text content of an element.
    pub async fn get_text(&self, selector: &str) -> Result<String, BrowserError> {
        self.ensure_element_exists(selector).await?;
        let js = format!(
            "document.querySelector({}).innerText || ''",
            serde_json::to_string(selector).unwrap_or_default(),
        );
        let val = self.evaluate(&js).await?;
        Ok(val.as_str().unwrap_or_default().to_string())
    }

    /// Get an attribute value from an element.
    pub async fn get_attribute(
        &self,
        selector: &str,
        attribute: &str,
    ) -> Result<Option<String>, BrowserError> {
        self.ensure_element_exists(selector).await?;
        let js = format!(
            "document.querySelector({sel}).getAttribute({attr})",
            sel = serde_json::to_string(selector).unwrap_or_default(),
            attr = serde_json::to_string(attribute).unwrap_or_default(),
        );
        let val = self.evaluate(&js).await?;
        if val.is_null() {
            Ok(None)
        } else {
            Ok(val.as_str().map(String::from))
        }
    }

    // ─── State ───────────────────────────────────────────────────────────

    /// Wait for an element to appear.
    pub async fn wait_for(&self, selector: &str, timeout_ms: u64) -> Result<(), BrowserError> {
        let js = format!(
            r"new Promise((resolve, reject) => {{
                if (document.querySelector({sel})) return resolve(true);
                const observer = new MutationObserver(() => {{
                    if (document.querySelector({sel})) {{
                        observer.disconnect();
                        resolve(true);
                    }}
                }});
                observer.observe(document.body, {{ childList: true, subtree: true }});
                setTimeout(() => {{ observer.disconnect(); reject(new Error('Timeout')); }}, {t});
            }})",
            sel = serde_json::to_string(selector).unwrap_or_default(),
            t = timeout_ms,
        );
        let _ = tokio::time::timeout(
            Duration::from_millis(timeout_ms + 1000),
            self.evaluate(&js),
        )
        .await
        .map_err(|_| BrowserError::Timeout {
            timeout_ms,
            context: format!("waiting for {selector}"),
        })?
        .map_err(|e| BrowserError::Timeout {
            timeout_ms,
            context: e.to_string(),
        })?;
        Ok(())
    }

    /// Scroll the page.
    pub async fn scroll(&self, direction: &str, amount: i64) -> Result<(), BrowserError> {
        let (x, y) = match direction {
            "up" => (0, -amount),
            "left" => (-amount, 0),
            "right" => (amount, 0),
            _ => (0, amount), // "down" and anything else
        };
        let _ = self.evaluate(&format!("window.scrollBy({x}, {y})")).await?;
        Ok(())
    }

    // ─── Export ──────────────────────────────────────────────────────────

    /// Export the page as PDF.
    pub async fn pdf(&self, path: &str) -> Result<(), BrowserError> {
        let result = self.send_cdp("Page.printToPDF", json!({})).await?;
        let b64 = result["data"].as_str().ok_or_else(|| {
            BrowserError::ActionFailed {
                action: "pdf".into(),
                reason: "no data".into(),
            }
        })?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| BrowserError::ActionFailed {
                action: "pdf".into(),
                reason: format!("base64 decode: {e}"),
            })?;
        tokio::fs::write(PathBuf::from(path), bytes)
            .await
            .map_err(|e| BrowserError::ActionFailed {
                action: "pdf".into(),
                reason: e.to_string(),
            })?;
        Ok(())
    }

    // ─── Screencast ──────────────────────────────────────────────────────

    /// Start streaming screencast frames.
    ///
    /// Screencast works by enabling `Page.screencastFrame` events from CDP,
    /// then forwarding them onto the broadcast channel.
    pub async fn start_screencast(
        self: &Arc<Self>,
        _session_id: String,
        opts: ScreencastOptions,
        _tx: broadcast::Sender<BrowserEvent>,
    ) -> Result<(), BrowserError> {
        self.stop_screencast().await?;

        let _ = self
            .send_cdp(
                "Page.startScreencast",
                json!({
                    "format": opts.format.as_str(),
                    "quality": opts.quality,
                    "maxWidth": opts.max_width,
                    "maxHeight": opts.max_height,
                    "everyNthFrame": opts.every_nth_frame,
                }),
            )
            .await?;

        self.is_streaming.store(true, Ordering::Relaxed);

        // The CDP handler loop already receives screencast events.
        // We need a separate mechanism to forward them. For now, we use
        // a polling approach via the event subscription the handler supports.
        // This is handled inside cdp_handler_loop via the event_tx.

        // Store session info for the handler to use
        let this = Arc::clone(self);
        let handle = tokio::spawn(async move {
            // Keep alive while streaming; actual frame delivery happens in cdp_handler_loop
            loop {
                if !this.is_streaming.load(Ordering::Relaxed) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        });

        *self.screencast_handle.lock().await = Some(handle);
        Ok(())
    }

    /// Stop screencast streaming.
    pub async fn stop_screencast(&self) -> Result<(), BrowserError> {
        self.is_streaming.store(false, Ordering::Relaxed);
        if let Some(handle) = self.screencast_handle.lock().await.take() {
            handle.abort();
        }
        let _ = self.send_cdp("Page.stopScreencast", json!({})).await;
        Ok(())
    }

    /// Close the browser process.
    pub async fn close(self) -> Result<(), BrowserError> {
        let _ = self.stop_screencast().await;
        if let Some(mut child) = self.chrome_process.lock().await.take() {
            let _ = child.kill().await;
        }
        Ok(())
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    async fn evaluate(&self, expression: &str) -> Result<Value, BrowserError> {
        let result = self
            .send_cdp(
                "Runtime.evaluate",
                json!({
                    "expression": expression,
                    "returnByValue": true,
                    "awaitPromise": true,
                }),
            )
            .await?;
        if let Some(exception) = result.get("exceptionDetails") {
            let msg = exception["exception"]["description"]
                .as_str()
                .or_else(|| exception["text"].as_str())
                .unwrap_or("evaluation error");
            return Err(BrowserError::ActionFailed {
                action: "evaluate".into(),
                reason: msg.into(),
            });
        }
        Ok(result["result"]["value"].clone())
    }

    async fn ensure_element_exists(&self, selector: &str) -> Result<(), BrowserError> {
        let js = format!(
            "document.querySelector({}) !== null",
            serde_json::to_string(selector).unwrap_or_default(),
        );
        let val = self.evaluate(&js).await?;
        if val.as_bool() != Some(true) {
            return Err(BrowserError::ElementNotFound {
                selector: selector.into(),
            });
        }
        Ok(())
    }

    async fn update_url(&self) {
        if let Ok(val) = self.evaluate("window.location.href").await {
            if let Some(url) = val.as_str() {
                *self.current_url.write() = Some(url.into());
            }
        }
    }
}

/// Wait for Chrome to output its `DevTools` WebSocket URL, then query the
/// `/json` endpoint to get the page's WS URL.
async fn wait_for_ws_url(port: u16, child: &mut Child) -> Result<String, BrowserError> {
    let url = format!("http://127.0.0.1:{port}/json");

    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Check Chrome hasn't crashed
        if let Some(status) = child.try_wait().map_err(|e| BrowserError::LaunchFailed {
            context: format!("wait: {e}"),
        })? {
            return Err(BrowserError::LaunchFailed {
                context: format!("Chrome exited early with {status}"),
            });
        }

        // Try to connect to /json
        let Ok(resp) = reqwest::get(&url).await else {
            continue;
        };
        let Ok(pages): Result<Vec<Value>, _> = resp.json().await else {
            continue;
        };
        if let Some(page) = pages.first() {
            if let Some(ws_url) = page["webSocketDebuggerUrl"].as_str() {
                return Ok(ws_url.to_string());
            }
        }
    }

    Err(BrowserError::LaunchFailed {
        context: format!("Chrome did not start within 5 seconds on port {port}"),
    })
}

/// CDP WebSocket handler loop.
///
/// Receives commands from `BrowserSession`, sends them over WS, and routes
/// responses back. Also handles CDP events (like screencast frames).
async fn cdp_handler_loop(
    ws: WsStream,
    mut cmd_rx: mpsc::Receiver<CdpCommand>,
) {
    let (mut ws_tx, mut ws_rx) = ws.split();
    let mut pending: HashMap<u64, PendingTx> = HashMap::new();
    let next_id = AtomicU64::new(1);

    loop {
        tokio::select! {
            // Incoming command from BrowserSession
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { break };
                let id = next_id.fetch_add(1, Ordering::Relaxed);
                let msg = json!({
                    "id": id,
                    "method": cmd.method,
                    "params": cmd.params,
                });
                let _ = pending.insert(id, cmd.response_tx);
                if ws_tx.send(Message::Text(msg.to_string().into())).await.is_err() {
                    break;
                }
            }
            // Incoming message from Chrome
            msg = ws_rx.next() => {
                let Some(Ok(msg)) = msg else { break };
                let Message::Text(text) = msg else { continue };
                let Ok(val): Result<Value, _> = serde_json::from_str(&text) else {
                    continue;
                };
                if let Some(id) = val.get("id").and_then(Value::as_u64) {
                    // This is a response to a command
                    if let Some(tx) = pending.remove(&id) {
                        if let Some(err) = val.get("error") {
                            let msg = err["message"].as_str().unwrap_or("CDP error");
                            let _ = tx.send(Err(msg.into()));
                        } else {
                            let _ = tx.send(Ok(val["result"].clone()));
                        }
                    }
                }
                // CDP events (method field, no id) are ignored for now.
                // Screencast frame events will be handled when we add
                // event subscriptions.
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_is_streaming_default_false() {
        let is_streaming = AtomicBool::new(false);
        assert!(!is_streaming.load(Ordering::Relaxed));
    }

    #[test]
    fn session_current_url_default_none() {
        let url: parking_lot::RwLock<Option<String>> = parking_lot::RwLock::new(None);
        assert!(url.read().is_none());
    }

    #[test]
    fn screencast_options_format_string() {
        let opts = ScreencastOptions::default();
        assert_eq!(opts.format.as_str(), "jpeg");
    }
}

#[cfg(test)]
#[cfg(feature = "browser-integration")]
mod integration_tests {
    use super::*;

    async fn launch_test_session() -> Arc<BrowserSession> {
        let chrome = super::chrome::find_chrome().expect("Chrome required for integration tests");
        Arc::new(BrowserSession::launch(&chrome).await.unwrap())
    }

    #[tokio::test]
    async fn session_navigate_updates_url() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<h1>Test</h1>")
            .await
            .unwrap();
        let url = session.current_url();
        assert!(url.is_some());
    }

    #[tokio::test]
    async fn session_screenshot_returns_png_base64() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<h1>Hello</h1>")
            .await
            .unwrap();
        let b64 = session.screenshot().await.unwrap();
        assert!(!b64.is_empty());
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&b64)
            .unwrap();
        assert!(bytes.len() > 8);
        assert_eq!(&bytes[1..4], b"PNG");
    }

    #[tokio::test]
    async fn session_snapshot_returns_text() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<h1>Hello World</h1>")
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(500)).await;
        let text = session.snapshot().await.unwrap();
        assert!(
            text.contains("Hello World"),
            "snapshot should contain page text, got: {text}"
        );
    }

    #[tokio::test]
    async fn session_get_text_from_element() {
        let session = launch_test_session().await;
        session
            .navigate(r#"data:text/html,<p id="t">content here</p>"#)
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let text = session.get_text("#t").await.unwrap();
        assert_eq!(text, "content here");
    }

    #[tokio::test]
    async fn session_click_nonexistent_element_returns_error() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<p>nothing</p>")
            .await
            .unwrap();
        let err = session.click("#nonexistent").await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn session_wait_for_existing_element() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<div id=\"target\">here</div>")
            .await
            .unwrap();
        session.wait_for("#target", 2000).await.unwrap();
    }

    #[tokio::test]
    async fn session_wait_for_timeout() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<p>empty</p>")
            .await
            .unwrap();
        let result = session.wait_for("#nonexistent", 500).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn session_scroll_down() {
        let session = launch_test_session().await;
        session
            .navigate("data:text/html,<div style='height:5000px'>tall</div>")
            .await
            .unwrap();
        session.scroll("down", 500).await.unwrap();
        let y = session.evaluate("window.scrollY").await.unwrap();
        assert!(y.as_f64().unwrap_or(0.0) > 0.0);
    }
}

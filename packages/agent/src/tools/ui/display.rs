//! `Display` tool — visual content presentation for the iOS app.
//!
//! Handles content types that can't be shown as inline chat text:
//! - **image/images** — screenshots, generated images, diagrams
//! - **stream** — live-updating views (browser windows, log tails)
//!
//! Text, links, and formatted content belong in the assistant's markdown
//! response — NOT in this tool. Use GetConfirmation for approval gates.
//!
//! ## Image handling
//!
//! Images are stored in blob storage. The result details contain a `blobId`
//! (NOT raw image data) to keep event payloads small and avoid exceeding
//! the 2MB WebSocket message limit. The iOS app fetches blob content via
//! the `blob.get` RPC when rendering.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine;
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{get_optional_string, validate_required_string};

const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024; // 10 MB

const SUPPORTED_IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff"];

/// Map a file extension to its MIME type.
fn mime_for_ext(ext: &str) -> &'static str {
    match ext {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "bmp" => "image/bmp",
        "tiff" => "image/tiff",
        _ => "application/octet-stream",
    }
}

/// The `Display` tool presents visual content to the user via the iOS app.
pub struct DisplayTool {
    blob_store: Option<Arc<dyn crate::tools::traits::BlobStore>>,
    /// Broadcast sender for emitting DisplayFrame events during streaming.
    event_tx: Option<tokio::sync::broadcast::Sender<crate::core::events::TronEvent>>,
}

impl DisplayTool {
    /// Create a new Display tool instance.
    pub fn new(blob_store: Option<Arc<dyn crate::tools::traits::BlobStore>>) -> Self {
        Self {
            blob_store,
            event_tx: None,
        }
    }

    /// Set the event broadcast sender for streaming support.
    #[must_use]
    pub fn with_event_tx(
        mut self,
        tx: tokio::sync::broadcast::Sender<crate::core::events::TronEvent>,
    ) -> Self {
        self.event_tx = Some(tx);
        self
    }
}

#[async_trait]
impl TronTool for DisplayTool {
    fn name(&self) -> &str {
        "Display"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Display",
            "Show visual content to the user in the iOS app. Use this ONLY for content that \
             can't be shown as inline chat text: images and live streams.\n\n\
             Do NOT use this for text, links, or formatted content — put those in your \
             regular markdown response instead.\n\n\
             Content types:\n\
             - **image**: Show an image from a file path (e.g., ComputerUse screenshot path) \
             or inline base64 data\n\
             - **images**: Show multiple images in a gallery\n\
             - **stream**: Open a live-updating view (for browser streams, log tails, etc.)\n\n\
             To stop an active stream, call with type=\"stream\", action=\"stop\", and the streamId.",
        )
        .required_property(
            "type",
            json!({
                "type": "string",
                "enum": ["image", "images", "stream"],
                "description": "The content type to display"
            }),
        )
        .property(
            "action",
            json!({
                "type": "string",
                "enum": ["start", "stop"],
                "description": "For stream type: 'start' (default) begins streaming, 'stop' ends an active stream"
            }),
        )
        .property(
            "title",
            json!({"type": "string", "description": "Optional header for the display sheet"}),
        )
        .property(
            "path",
            json!({"type": "string", "description": "File path for a single image (e.g., from ComputerUse screenshot)"}),
        )
        .property(
            "data",
            json!({"type": "string", "description": "Base64-encoded image data (alternative to path)"}),
        )
        .property(
            "mimeType",
            json!({"type": "string", "description": "MIME type for base64 data (default: image/png)", "default": "image/png"}),
        )
        .property(
            "paths",
            json!({
                "type": "array",
                "items": {"type": "string"},
                "description": "File paths for multiple images (gallery)"
            }),
        )
        .property(
            "streamId",
            json!({"type": "string", "description": "Stream identifier (for stream type)"}),
        )
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let content_type = match validate_required_string(&params, "type", "content type") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let title = get_optional_string(&params, "title");

        let action = get_optional_string(&params, "action")
            .unwrap_or_else(|| "start".to_string());

        let result = match content_type.as_str() {
            "image" => self.handle_image(&params).await,
            "images" => self.handle_images(&params).await,
            "stream" if action == "stop" => self.handle_stop_stream(&params, _ctx).await,
            "stream" => self.handle_stream(&params, _ctx).await,
            other => Ok(error_result(format!(
                "Unsupported content type: '{other}'. Supported: image, images, stream."
            ))),
        };

        match result {
            Ok(mut tool_result) => {
                let mut details = tool_result.details.unwrap_or_else(|| json!({}));
                details["displayType"] = json!(content_type);
                if let Some(ref t) = title {
                    details["title"] = json!(t);
                }
                tool_result.details = Some(details);
                Ok(tool_result)
            }
            Err(e) => Err(e),
        }
    }
}

impl DisplayTool {
    /// Handle `image` type — from file path OR inline base64 data.
    /// Image bytes are stored in blob storage; details contain `blobId` + `mimeType`.
    async fn handle_image(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let inline_data = get_optional_string(params, "data");
        let path = get_optional_string(params, "path");

        let (image_bytes, mime) = if let Some(ref b64) = inline_data {
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(b64)
                .map_err(|e| ToolError::Validation {
                    message: format!("Invalid base64 data: {e}"),
                })?;
            let mime = get_optional_string(params, "mimeType")
                .unwrap_or_else(|| "image/png".to_string());
            (decoded, mime)
        } else if let Some(ref path) = path {
            let (bytes, mime) = self.read_file(path, SUPPORTED_IMAGE_EXTS, MAX_IMAGE_BYTES, "Image").await?;
            (bytes, mime.to_string())
        } else {
            return Ok(error_result(
                "Missing 'path' or 'data' parameter for image type.",
            ));
        };

        let size = image_bytes.len();
        let blob_id = self.store_blob(&image_bytes, &mime).await?;

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Displaying image ({size} bytes)"
                )),
            ]),
            details: Some(json!({
                "blobId": blob_id,
                "mimeType": mime,
                "sizeBytes": size,
            })),
            is_error: None,
            stop_turn: None,
        })
    }

    /// Handle `images` type — multiple file paths, each stored in blob storage.
    async fn handle_images(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let paths: Vec<String> = params
            .get("paths")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();

        if paths.is_empty() {
            return Ok(error_result("Missing or empty 'paths' array for images type."));
        }

        let mut images_data: Vec<Value> = Vec::with_capacity(paths.len());
        for path in &paths {
            let (bytes, mime) = self.read_file(path, SUPPORTED_IMAGE_EXTS, MAX_IMAGE_BYTES, "Image").await?;
            let blob_id = self.store_blob(&bytes, mime).await?;
            images_data.push(json!({"blobId": blob_id, "mimeType": mime, "path": path}));
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Displaying {} images", paths.len()
                )),
            ]),
            details: Some(json!({"images": images_data})),
            is_error: None,
            stop_turn: None,
        })
    }

    /// Handle `stream` type — start a screen capture loop in the background
    /// and return immediately so the agent can continue working.
    ///
    /// The producer runs as a detached tokio task tied to the session's
    /// cancellation token. When the session ends or is aborted, the token
    /// fires, the producer stops, and the last frame is saved to blob storage
    /// via a fire-and-forget cleanup task.
    async fn handle_stream(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let stream_id = match get_optional_string(params, "streamId") {
            Some(s) => s,
            None => return Ok(error_result("Missing 'streamId' parameter for stream type.")),
        };

        let event_tx = match self.event_tx.as_ref() {
            Some(tx) => tx.clone(),
            None => {
                return Ok(error_result(
                    "Streaming not available (event emitter not configured).",
                ))
            }
        };

        let pm = match ctx.process_manager.as_ref() {
            Some(pm) => pm.clone(),
            None => {
                return Ok(error_result(
                    "Streaming not available (process manager not configured).",
                ))
            }
        };

        // Check for duplicate streams.
        if pm.find_by_label(&ctx.session_id, "display_stream:").is_some() {
            return Ok(error_result(
                "A display stream is already active. Stop it first with Display(type=\"stream\", action=\"stop\", streamId=\"...\").",
            ));
        }

        let config = crate::tools::ui::display_stream::StreamConfig {
            interval: std::time::Duration::from_millis(
                crate::tools::ui::display_stream::DEFAULT_INTERVAL_MS,
            ),
            session_id: ctx.session_id.clone(),
            stream_id: stream_id.clone(),
            tool_call_id: ctx.tool_call_id.clone(),
        };

        let blob_store = self.blob_store.clone();
        // Use an independent token — NOT a child of ctx.cancellation.
        // Background streams must survive agent turn interruptions. The
        // ProcessManager owns the lifecycle: its cancel_process() drops the
        // task future, which breaks the capture loop. A child token would
        // cause the stream to die whenever the user interrupts the agent.
        let stream_cancel = CancellationToken::new();

        let task: std::pin::Pin<Box<dyn std::future::Future<Output = crate::tools::traits::ManagedProcessResult> + Send>> = Box::pin(async move {
            let start = std::time::Instant::now();
            let last_frame_data =
                crate::tools::ui::display_stream::screen_capture_loop(
                    event_tx, config, stream_cancel,
                )
                .await;

            // Save last frame to blob storage for the static fallback.
            let mut blob_id = None;
            if let (Some(data), Some(store)) = (last_frame_data, blob_store) {
                match store.store(&data, "image/jpeg").await {
                    Ok(id) => {
                        tracing::debug!(blob_id = %id, "Saved last stream frame to blob");
                        blob_id = Some(id);
                    }
                    Err(e) => tracing::warn!(error = %e, "Failed to save last stream frame"),
                }
            }

            crate::tools::traits::ManagedProcessResult {
                process_id: String::new(),
                output: "Stream ended".into(),
                exit_code: None,
                duration_ms: start.elapsed().as_millis() as u64,
                timed_out: false,
                cancelled: false,
                blob_id,
            }
        });

        let pm_config = crate::tools::traits::ManagedProcessConfig {
            label: format!("display_stream:{stream_id}"),
            kind: crate::tools::traits::ProcessKind::DisplayStream,
            timeout_ms: None,
            sandbox: false,
        };

        let handle = pm
            .spawn_managed(
                &ctx.session_id,
                &ctx.tool_call_id,
                pm_config,
                task,
                true, // always background
            )
            .await?;

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Screen stream '{stream_id}' started. Frames are being sent to the user's device at ~3 FPS. \
                     The stream will continue in the background while you work. \
                     To stop it, call Display(type=\"stream\", action=\"stop\", streamId=\"{stream_id}\")."
                )),
            ]),
            details: Some(json!({
                "streamId": stream_id,
                "processId": handle.process_id,
                "streaming": true,
            })),
            is_error: None,
            stop_turn: None,
        })
    }

    /// Handle `stream` + `action: "stop"` — cancel an active stream via ProcessManager.
    async fn handle_stop_stream(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let stream_id = match get_optional_string(params, "streamId") {
            Some(s) => s,
            None => return Ok(error_result("Missing 'streamId' parameter for stream stop.")),
        };

        let pm = match ctx.process_manager.as_ref() {
            Some(pm) => pm,
            None => return Ok(error_result("Process manager not available.")),
        };

        let label = format!("display_stream:{stream_id}");
        if let Some(process_id) = pm.find_by_label(&ctx.session_id, &label) {
            pm.cancel_process(&process_id)?;
            Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Stream '{stream_id}' stopped."
                    )),
                ]),
                details: Some(json!({
                    "streamId": stream_id,
                    "processId": process_id,
                    "streaming": false,
                })),
                is_error: None,
                stop_turn: None,
            })
        } else {
            Ok(error_result(format!(
                "No active stream with ID '{stream_id}'."
            )))
        }
    }

    /// Read a file, validate it, and return `(raw_bytes, mime_type)`.
    async fn read_file(
        &self,
        path: &str,
        supported_exts: &[&str],
        max_bytes: u64,
        kind: &str,
    ) -> Result<(Vec<u8>, &'static str), ToolError> {
        self.validate_file(path, supported_exts, max_bytes, kind)?;

        let file_path = Path::new(path);
        let ext = file_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        let mime = mime_for_ext(&ext);

        let data = tokio::fs::read(file_path)
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to read file: {e}"),
            })?;

        Ok((data, mime))
    }

    /// Store content in blob storage. Returns the blob ID.
    async fn store_blob(&self, content: &[u8], mime_type: &str) -> Result<String, ToolError> {
        match self.blob_store.as_ref() {
            Some(store) => store.store(content, mime_type).await,
            None => {
                let b64 = base64::engine::general_purpose::STANDARD.encode(content);
                Ok(format!("inline:{b64}"))
            }
        }
    }

    /// Validate a file exists, has a supported extension, and is within size limits.
    fn validate_file(
        &self,
        path: &str,
        supported_exts: &[&str],
        max_bytes: u64,
        kind: &str,
    ) -> Result<(), ToolError> {
        let file_path = Path::new(path);

        if !file_path.exists() {
            return Err(ToolError::Validation {
                message: format!("File not found: {path}"),
            });
        }

        let ext = file_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();

        if !supported_exts.contains(&ext.as_str()) {
            return Err(ToolError::Validation {
                message: format!(
                    "Unsupported {kind} format: '.{ext}'. Supported: {}",
                    supported_exts.join(", ")
                ),
            });
        }

        let metadata = std::fs::metadata(file_path).map_err(|e| ToolError::Internal {
            message: format!("Failed to read file metadata: {e}"),
        })?;

        if metadata.len() > max_bytes {
            let max_mb = max_bytes / (1024 * 1024);
            let actual_mb = metadata.len() / (1024 * 1024);
            return Err(ToolError::Validation {
                message: format!(
                    "{kind} exceeds {max_mb}MB limit ({actual_mb}MB). Please use a smaller file.",
                ),
            });
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::make_ctx;
    use std::io::Write;
    use tempfile::NamedTempFile;

    // ── Schema ─────────────────────────────────────────────────

    #[test]
    fn schema_has_correct_parameters() {
        let tool = DisplayTool::new(None);
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        for key in &["type", "action", "title", "path", "data", "mimeType", "paths", "streamId"] {
            assert!(props.contains_key(*key), "missing schema property: {key}");
        }
        // Removed params should NOT be present
        for key in &["content", "url", "label", "autoplay", "interactive"] {
            assert!(!props.contains_key(*key), "removed property still present: {key}");
        }
        let required = def.parameters.required.as_ref().unwrap();
        assert_eq!(required, &["type"]);
    }

    #[test]
    fn schema_enum_only_has_image_images_stream() {
        let tool = DisplayTool::new(None);
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        let type_enum = props["type"]["enum"].as_array().unwrap();
        let types: Vec<&str> = type_enum.iter().filter_map(|v| v.as_str()).collect();
        assert_eq!(types, vec!["image", "images", "stream"]);
    }

    #[test]
    fn tool_name_and_category() {
        let tool = DisplayTool::new(None);
        assert_eq!(tool.name(), "Display");
        assert_eq!(tool.category(), ToolCategory::Custom);
    }

    // ── Image from path ────────────────────────────────────────

    #[tokio::test]
    async fn image_path_produces_blob_id() {
        let mut tmp = NamedTempFile::with_suffix(".png").unwrap();
        write!(tmp, "fake png data").unwrap();
        let path = tmp.path().to_string_lossy().to_string();

        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "path": path}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["displayType"], "image");
        assert_eq!(details["mimeType"], "image/png");
        assert!(details["blobId"].as_str().unwrap().starts_with("inline:"));
    }

    #[tokio::test]
    async fn image_path_jpeg_has_correct_mime() {
        let mut tmp = NamedTempFile::with_suffix(".jpg").unwrap();
        write!(tmp, "jpeg data").unwrap();

        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "image", "path": tmp.path().to_string_lossy().to_string()}), &make_ctx())
            .await.unwrap();
        assert_eq!(r.details.unwrap()["mimeType"], "image/jpeg");
    }

    // ── Image from inline base64 ───────────────────────────────

    #[tokio::test]
    async fn image_with_data_param() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"inline image bytes");
        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "image", "data": b64, "mimeType": "image/jpeg"}), &make_ctx())
            .await.unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert!(details["blobId"].as_str().is_some());
        assert_eq!(details["mimeType"], "image/jpeg");
    }

    #[tokio::test]
    async fn image_data_defaults_to_png_mime() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"data");
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "data": b64}), &make_ctx()).await.unwrap();
        assert_eq!(r.details.unwrap()["mimeType"], "image/png");
    }

    #[tokio::test]
    async fn image_data_invalid_base64() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "data": "not valid!!!"}), &make_ctx()).await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("Invalid base64"));
    }

    #[tokio::test]
    async fn image_data_takes_priority_over_path() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"priority");
        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "image", "data": b64, "path": "/nonexistent.png"}), &make_ctx())
            .await.unwrap();
        assert!(r.is_error.is_none());
    }

    // ── Image validation ───────────────────────────────────────

    #[tokio::test]
    async fn image_missing_file() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "path": "/nonexistent.png"}), &make_ctx()).await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("File not found"));
    }

    #[tokio::test]
    async fn image_too_large() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("huge.png");
        std::fs::write(&path, vec![0u8; (MAX_IMAGE_BYTES + 1) as usize]).unwrap();

        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "path": path.to_string_lossy().to_string()}), &make_ctx()).await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("limit"));
    }

    #[tokio::test]
    async fn image_unsupported_format() {
        let mut tmp = NamedTempFile::with_suffix(".exe").unwrap();
        write!(tmp, "data").unwrap();

        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "path": tmp.path().to_string_lossy().to_string()}), &make_ctx()).await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("Unsupported"));
    }

    #[tokio::test]
    async fn image_no_path_or_data() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn image_no_extension() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("noext");
        std::fs::write(&path, "data").unwrap();

        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "image", "path": path.to_string_lossy().to_string()}), &make_ctx()).await;
        assert!(r.is_err());
    }

    // ── Images (gallery) ───────────────────────────────────────

    #[tokio::test]
    async fn images_stores_all_as_blobs() {
        let mut t1 = NamedTempFile::with_suffix(".jpg").unwrap();
        let mut t2 = NamedTempFile::with_suffix(".png").unwrap();
        write!(t1, "img1").unwrap();
        write!(t2, "img2").unwrap();

        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "images", "paths": [
                t1.path().to_string_lossy().to_string(),
                t2.path().to_string_lossy().to_string()
            ]}), &make_ctx())
            .await.unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        let images = details["images"].as_array().unwrap();
        assert_eq!(images.len(), 2);
        assert!(images[0]["blobId"].as_str().is_some());
        assert_eq!(images[0]["mimeType"], "image/jpeg");
        assert_eq!(images[1]["mimeType"], "image/png");
    }

    #[tokio::test]
    async fn images_empty_array() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "images", "paths": []}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn images_one_bad_path() {
        let mut t1 = NamedTempFile::with_suffix(".jpg").unwrap();
        write!(t1, "data").unwrap();

        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "images", "paths": [
                t1.path().to_string_lossy().to_string(),
                "/nonexistent.png"
            ]}), &make_ctx())
            .await;
        assert!(r.is_err());
    }

    // ── Stream ─────────────────────────────────────────────────

    #[tokio::test]
    async fn stream_missing_id() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "stream"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn stream_no_event_tx_returns_error() {
        let tool = DisplayTool::new(None); // no event_tx
        let r = tool
            .execute(json!({"type": "stream", "streamId": "s1"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    fn make_stream_ctx() -> ToolContext {
        let mut ctx = make_ctx();
        let pm = std::sync::Arc::new(
            crate::runtime::orchestrator::process_manager::ProcessManager::new(),
        );
        ctx.process_manager = Some(pm);
        ctx
    }

    #[tokio::test]
    async fn stream_stop_cancels_active_stream() {
        let (tx, _rx) = tokio::sync::broadcast::channel::<crate::core::events::TronEvent>(64);
        let tool = DisplayTool::new(None).with_event_tx(tx);
        let ctx = make_stream_ctx();

        // Start a stream
        let r = tool
            .execute(json!({"type": "stream", "streamId": "stop-test"}), &ctx)
            .await
            .unwrap();
        assert!(r.is_error.is_none());

        // Stop it
        let r = tool
            .execute(json!({"type": "stream", "action": "stop", "streamId": "stop-test"}), &ctx)
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["streamId"], "stop-test");
        assert_eq!(details["streaming"], false);
    }

    #[tokio::test]
    async fn stream_stop_nonexistent_returns_error() {
        let tool = DisplayTool::new(None);
        let ctx = make_stream_ctx();
        let r = tool
            .execute(json!({"type": "stream", "action": "stop", "streamId": "nope"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn stream_stop_missing_id() {
        let tool = DisplayTool::new(None);
        let ctx = make_stream_ctx();
        let r = tool
            .execute(json!({"type": "stream", "action": "stop"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn stream_no_process_manager_returns_error() {
        let (tx, _rx) = tokio::sync::broadcast::channel::<crate::core::events::TronEvent>(64);
        let tool = DisplayTool::new(None).with_event_tx(tx);
        let r = tool
            .execute(json!({"type": "stream", "streamId": "s1"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn stream_returns_immediately() {
        let (tx, _rx) = tokio::sync::broadcast::channel::<crate::core::events::TronEvent>(64);
        let tool = DisplayTool::new(None).with_event_tx(tx);
        let ctx = make_stream_ctx();

        let r = tool
            .execute(json!({"type": "stream", "streamId": "test-stream"}), &ctx)
            .await
            .unwrap();

        // Tool should return immediately (not block).
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["streamId"], "test-stream");
        assert_eq!(details["streaming"], true);
        assert_eq!(details["displayType"], "stream");
    }

    // ── General ────────────────────────────────────────────────

    #[tokio::test]
    async fn unknown_type_returns_error() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({"type": "markdown"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_type_returns_error() {
        let tool = DisplayTool::new(None);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn title_flows_to_details() {
        let mut tmp = NamedTempFile::with_suffix(".png").unwrap();
        write!(tmp, "data").unwrap();
        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "image", "path": tmp.path().to_string_lossy().to_string(), "title": "My Title"}), &make_ctx())
            .await.unwrap();
        assert_eq!(r.details.unwrap()["title"], "My Title");
    }

    #[tokio::test]
    async fn title_absent_not_in_details() {
        let mut tmp = NamedTempFile::with_suffix(".png").unwrap();
        write!(tmp, "data").unwrap();
        let tool = DisplayTool::new(None);
        let r = tool
            .execute(json!({"type": "image", "path": tmp.path().to_string_lossy().to_string()}), &make_ctx())
            .await.unwrap();
        assert!(r.details.unwrap().get("title").is_none());
    }

    #[test]
    fn mime_type_mapping() {
        assert_eq!(mime_for_ext("png"), "image/png");
        assert_eq!(mime_for_ext("jpg"), "image/jpeg");
        assert_eq!(mime_for_ext("jpeg"), "image/jpeg");
        assert_eq!(mime_for_ext("gif"), "image/gif");
        assert_eq!(mime_for_ext("unknown"), "application/octet-stream");
    }
}

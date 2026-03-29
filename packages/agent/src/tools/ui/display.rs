//! `Display` tool — general-purpose rich content presentation.
//!
//! Allows the agent to present images, markdown, links, audio, and streaming
//! content to the user via the iOS app. This is the visual output primitive,
//! complementing `AskUserQuestion` (interactive input) and `NotifyApp` (push
//! notifications).
//!
//! Content types:
//! - `image` — Single image from a file path
//! - `images` — Multiple images (gallery/comparison)
//! - `markdown` — Formatted text, code blocks, tables
//! - `link` — URL with optional label
//! - `audio` — Audio file playback
//! - `stream` — Live-updating view (identifier only; frames sent via updates)

use std::path::Path;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{get_optional_bool, get_optional_string, validate_required_string};

const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024; // 10 MB
const MAX_AUDIO_BYTES: u64 = 50 * 1024 * 1024; // 50 MB

const SUPPORTED_IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff"];
const SUPPORTED_AUDIO_EXTS: &[&str] = &["mp3", "wav", "m4a", "aac", "ogg", "flac"];

/// The `Display` tool presents rich content to the user via the iOS app.
pub struct DisplayTool;

impl DisplayTool {
    /// Create a new Display tool instance.
    pub fn new() -> Self {
        Self
    }
}

impl Default for DisplayTool {
    fn default() -> Self {
        Self::new()
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
            "Present rich content to the user in the iOS app. Use this to show images, \
             formatted text, links, or audio that would be better displayed in a dedicated \
             sheet rather than inline text.\n\n\
             Content types:\n\
             - **image**: Show a single image from a file path\n\
             - **images**: Show multiple images in a gallery\n\
             - **markdown**: Show formatted text with code blocks, tables, etc.\n\
             - **link**: Show a URL with optional label\n\
             - **audio**: Play an audio file\n\
             - **stream**: Open a live-updating view (for browser streams, log tails, etc.)",
        )
        .required_property(
            "type",
            json!({
                "type": "string",
                "enum": ["image", "images", "markdown", "link", "audio", "stream"],
                "description": "The content type to display"
            }),
        )
        .property("title", json!({"type": "string", "description": "Optional header for the display sheet"}))
        .property("path", json!({"type": "string", "description": "File path (for image/audio types)"}))
        .property(
            "paths",
            json!({
                "type": "array",
                "items": {"type": "string"},
                "description": "File paths (for images type)"
            }),
        )
        .property("content", json!({"type": "string", "description": "Markdown content (for markdown type)"}))
        .property("url", json!({"type": "string", "description": "URL (for link type)"}))
        .property("label", json!({"type": "string", "description": "Link text (for link type)"}))
        .property("streamId", json!({"type": "string", "description": "Stream identifier (for stream type)"}))
        .property("autoplay", json!({"type": "boolean", "description": "Auto-play audio (default false)", "default": false}))
        .property("interactive", json!({"type": "boolean", "description": "If true, stops turn and waits for user acknowledgment", "default": false}))
        .build()
    }

    async fn execute(&self, params: Value, _ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let content_type = match validate_required_string(&params, "type", "content type") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let title = get_optional_string(&params, "title");
        let interactive = get_optional_bool(&params, "interactive").unwrap_or(false);

        let result = match content_type.as_str() {
            "image" => self.handle_image(&params).await,
            "images" => self.handle_images(&params).await,
            "markdown" => self.handle_markdown(&params),
            "link" => self.handle_link(&params),
            "audio" => self.handle_audio(&params).await,
            "stream" => self.handle_stream(&params),
            other => Ok(error_result(format!(
                "Unsupported content type: '{other}'. Supported: image, images, markdown, link, audio, stream."
            ))),
        };

        match result {
            Ok(mut tool_result) => {
                // Enrich details with display metadata.
                let mut details = tool_result.details.unwrap_or_else(|| json!({}));
                details["displayType"] = json!(content_type);
                if let Some(ref t) = title {
                    details["title"] = json!(t);
                }
                tool_result.details = Some(details);
                tool_result.stop_turn = if interactive { Some(true) } else { None };
                Ok(tool_result)
            }
            Err(e) => Err(e),
        }
    }
}

impl DisplayTool {
    async fn handle_image(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let path = match get_optional_string(params, "path") {
            Some(p) => p,
            None => return Ok(error_result("Missing 'path' parameter for image type.")),
        };

        self.validate_file(&path, SUPPORTED_IMAGE_EXTS, MAX_IMAGE_BYTES, "Image")
            .await?;

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!("Displaying image: {path}")),
            ]),
            details: Some(json!({"path": path})),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn handle_images(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let paths: Vec<String> = params
            .get("paths")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();

        if paths.is_empty() {
            return Ok(error_result("Missing or empty 'paths' array for images type."));
        }

        for path in &paths {
            self.validate_file(path, SUPPORTED_IMAGE_EXTS, MAX_IMAGE_BYTES, "Image")
                .await?;
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Displaying {} images",
                    paths.len()
                )),
            ]),
            details: Some(json!({"paths": paths})),
            is_error: None,
            stop_turn: None,
        })
    }

    fn handle_markdown(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let content = match get_optional_string(params, "content") {
            Some(c) if !c.is_empty() => c,
            _ => {
                return Ok(error_result(
                    "Missing or empty 'content' parameter for markdown type.",
                ))
            }
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text("Displaying markdown content"),
            ]),
            details: Some(json!({"content": content})),
            is_error: None,
            stop_turn: None,
        })
    }

    fn handle_link(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let url = match get_optional_string(params, "url") {
            Some(u) => u,
            None => return Ok(error_result("Missing 'url' parameter for link type.")),
        };
        let label = get_optional_string(params, "label");

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Displaying link: {}",
                    label.as_deref().unwrap_or(&url)
                )),
            ]),
            details: Some(json!({"url": url, "label": label})),
            is_error: None,
            stop_turn: None,
        })
    }

    async fn handle_audio(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let path = match get_optional_string(params, "path") {
            Some(p) => p,
            None => return Ok(error_result("Missing 'path' parameter for audio type.")),
        };

        self.validate_file(&path, SUPPORTED_AUDIO_EXTS, MAX_AUDIO_BYTES, "Audio")
            .await?;

        let autoplay = get_optional_bool(params, "autoplay").unwrap_or(false);

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!("Displaying audio: {path}")),
            ]),
            details: Some(json!({"path": path, "autoplay": autoplay})),
            is_error: None,
            stop_turn: None,
        })
    }

    fn handle_stream(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let stream_id = match get_optional_string(params, "streamId") {
            Some(s) => s,
            None => return Ok(error_result("Missing 'streamId' parameter for stream type.")),
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Opening stream: {stream_id}"
                )),
            ]),
            details: Some(json!({"streamId": stream_id})),
            is_error: None,
            stop_turn: None,
        })
    }

    /// Validate a file exists, has a supported extension, and is within size limits.
    async fn validate_file(
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

        // Check extension
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

        // Check file size
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
    fn schema_has_all_parameters() {
        let tool = DisplayTool::new();
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        for key in &[
            "type", "title", "path", "paths", "content", "url", "label", "streamId", "autoplay",
            "interactive",
        ] {
            assert!(props.contains_key(*key), "missing schema property: {key}");
        }
        let required = def.parameters.required.as_ref().unwrap();
        assert!(required.contains(&"type".to_string()));
        assert_eq!(required.len(), 1, "only 'type' should be required");
    }

    #[test]
    fn tool_name_and_category() {
        let tool = DisplayTool::new();
        assert_eq!(tool.name(), "Display");
        assert_eq!(tool.category(), ToolCategory::Custom);
    }

    // ── Image ──────────────────────────────────────────────────

    #[tokio::test]
    async fn image_valid_png() {
        let mut tmp = NamedTempFile::with_suffix(".png").unwrap();
        write!(tmp, "fake png data").unwrap();
        let path = tmp.path().to_string_lossy().to_string();

        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "image", "path": path}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["displayType"], "image");
        assert_eq!(details["path"].as_str().unwrap(), path);
    }

    #[tokio::test]
    async fn image_missing_file() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "path": "/nonexistent/file.png"}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("File not found"));
    }

    #[tokio::test]
    async fn image_too_large() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("huge.png");
        let data = vec![0u8; (MAX_IMAGE_BYTES + 1) as usize];
        std::fs::write(&path, &data).unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "path": path.to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("limit"));
    }

    #[tokio::test]
    async fn image_unsupported_format() {
        let mut tmp = NamedTempFile::with_suffix(".exe").unwrap();
        write!(tmp, "data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "path": tmp.path().to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("Unsupported"));
    }

    #[tokio::test]
    async fn image_no_path_param() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "image"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn image_no_extension() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("noext");
        std::fs::write(&path, "data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "path": path.to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("Unsupported"));
    }

    // ── Images ─────────────────────────────────────────────────

    #[tokio::test]
    async fn images_valid_multiple() {
        let mut t1 = NamedTempFile::with_suffix(".jpg").unwrap();
        let mut t2 = NamedTempFile::with_suffix(".png").unwrap();
        write!(t1, "data1").unwrap();
        write!(t2, "data2").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "images", "paths": [
                    t1.path().to_string_lossy().to_string(),
                    t2.path().to_string_lossy().to_string()
                ]}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["paths"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn images_empty_array() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "images", "paths": []}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn images_one_bad_path() {
        let mut t1 = NamedTempFile::with_suffix(".jpg").unwrap();
        write!(t1, "data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "images", "paths": [
                    t1.path().to_string_lossy().to_string(),
                    "/nonexistent.png"
                ]}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
    }

    // ── Markdown ───────────────────────────────────────────────

    #[tokio::test]
    async fn markdown_valid() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "markdown", "content": "# Hello\nWorld"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["displayType"], "markdown");
        assert_eq!(details["content"], "# Hello\nWorld");
    }

    #[tokio::test]
    async fn markdown_empty_content() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "markdown", "content": ""}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn markdown_missing_content() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "markdown"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Link ───────────────────────────────────────────────────

    #[tokio::test]
    async fn link_valid_with_label() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "link", "url": "https://example.com", "label": "Example"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["url"], "https://example.com");
        assert_eq!(details["label"], "Example");
    }

    #[tokio::test]
    async fn link_valid_without_label() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "link", "url": "https://example.com"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn link_missing_url() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "link"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Audio ──────────────────────────────────────────────────

    #[tokio::test]
    async fn audio_valid_mp3() {
        let mut tmp = NamedTempFile::with_suffix(".mp3").unwrap();
        write!(tmp, "audio data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "audio", "path": tmp.path().to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["autoplay"], false);
    }

    #[tokio::test]
    async fn audio_with_autoplay() {
        let mut tmp = NamedTempFile::with_suffix(".wav").unwrap();
        write!(tmp, "audio data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "audio", "path": tmp.path().to_string_lossy().to_string(), "autoplay": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["autoplay"], true);
    }

    #[tokio::test]
    async fn audio_unsupported_format() {
        let mut tmp = NamedTempFile::with_suffix(".wma").unwrap();
        write!(tmp, "data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "audio", "path": tmp.path().to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("Unsupported"));
    }

    #[tokio::test]
    async fn audio_missing_file() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "audio", "path": "/nonexistent/audio.mp3"}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
    }

    #[tokio::test]
    async fn audio_too_large() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("huge.mp3");
        let data = vec![0u8; (MAX_AUDIO_BYTES + 1) as usize];
        std::fs::write(&path, &data).unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "audio", "path": path.to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("limit"));
    }

    // ── Stream ─────────────────────────────────────────────────

    #[tokio::test]
    async fn stream_valid() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "stream", "streamId": "browser-123"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["streamId"], "browser-123");
        assert_eq!(details["displayType"], "stream");
    }

    #[tokio::test]
    async fn stream_missing_id() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "stream"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Interactive mode ───────────────────────────────────────

    #[tokio::test]
    async fn interactive_true_stops_turn() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "markdown", "content": "Review this", "interactive": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.stop_turn, Some(true));
    }

    #[tokio::test]
    async fn interactive_false_does_not_stop() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "markdown", "content": "FYI"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.stop_turn.is_none());
    }

    // ── General / edge cases ───────────────────────────────────

    #[tokio::test]
    async fn unknown_type_returns_error() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "video"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_type_returns_error() {
        let tool = DisplayTool::new();
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn title_flows_to_details() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "markdown", "content": "text", "title": "My Title"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["title"], "My Title");
    }

    #[tokio::test]
    async fn title_absent_not_in_details() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "markdown", "content": "text"}), &make_ctx())
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert!(details.get("title").is_none());
    }

    #[tokio::test]
    async fn display_type_always_in_details() {
        for dtype in &["markdown", "link", "stream"] {
            let params = match *dtype {
                "markdown" => json!({"type": dtype, "content": "x"}),
                "link" => json!({"type": dtype, "url": "https://x.com"}),
                "stream" => json!({"type": dtype, "streamId": "s1"}),
                _ => unreachable!(),
            };
            let tool = DisplayTool::new();
            let r = tool.execute(params, &make_ctx()).await.unwrap();
            let details = r.details.unwrap();
            assert_eq!(
                details["displayType"].as_str().unwrap(),
                *dtype,
                "displayType mismatch for {dtype}"
            );
        }
    }
}

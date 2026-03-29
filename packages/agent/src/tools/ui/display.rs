//! `Display` tool — general-purpose rich content presentation.
//!
//! Allows the agent to present images, markdown, links, audio, and streaming
//! content to the user via the iOS app. This is the visual output primitive,
//! complementing `AskUserQuestion` (interactive input) and `NotifyApp` (push
//! notifications).
//!
//! ## Image handling
//!
//! Images can be provided in two ways:
//! - **`path`**: Server reads the file and base64-encodes it into the result
//!   details, so the iOS app can render without filesystem access.
//! - **`data`**: Base64-encoded image data passed directly (e.g., from
//!   ComputerUse screenshot output), skipping file I/O entirely.
//!
//! The iOS app always renders from `details.imageData` (base64), never from
//! file paths — the server and client may be on different machines.

use std::path::Path;

use async_trait::async_trait;
use base64::Engine;
use serde_json::{Value, json};

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{
    get_optional_bool, get_optional_string, validate_required_string,
};

const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024; // 10 MB
const MAX_AUDIO_BYTES: u64 = 50 * 1024 * 1024; // 50 MB

const SUPPORTED_IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff"];
const SUPPORTED_AUDIO_EXTS: &[&str] = &["mp3", "wav", "m4a", "aac", "ogg", "flac"];

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
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "ogg" => "audio/ogg",
        "flac" => "audio/flac",
        _ => "application/octet-stream",
    }
}

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
             - **image**: Show an image. Pass base64 via `data` or a file path via `path`.\n\
             - **images**: Show multiple images in a gallery (file paths).\n\
             - **markdown**: Show formatted text with code blocks, tables, etc.\n\
             - **link**: Show a URL with optional label.\n\
             - **audio**: Play an audio file from a path.\n\
             - **stream**: Open a live-updating view (for browser streams, log tails, etc.).\n\n\
             ## Images\n\
             When you already have image data in memory (e.g., a ComputerUse screenshot returns \
             base64 image data), pass it directly via the `data` parameter — do NOT save to disk \
             first. Use `path` only when the image is already a file on disk.\n\n\
             Example with ComputerUse screenshot: take screenshot → pass the returned base64 data \
             straight to Display(type: \"image\", data: \"<base64>\", title: \"Screenshot\").",
        )
        .required_property(
            "type",
            json!({
                "type": "string",
                "enum": ["image", "images", "markdown", "link", "audio", "stream"],
                "description": "The content type to display"
            }),
        )
        .property(
            "title",
            json!({"type": "string", "description": "Optional header for the display sheet"}),
        )
        .property(
            "path",
            json!({"type": "string", "description": "File path (for image/audio types)"}),
        )
        .property(
            "data",
            json!({"type": "string", "description": "Base64-encoded image data (alternative to path for image type). Use this when you already have the image in memory, e.g., from a ComputerUse screenshot."}),
        )
        .property(
            "mimeType",
            json!({"type": "string", "description": "MIME type for base64 data (default: image/png). Only used with 'data' parameter.", "default": "image/png"}),
        )
        .property(
            "paths",
            json!({
                "type": "array",
                "items": {"type": "string"},
                "description": "File paths (for images type)"
            }),
        )
        .property(
            "content",
            json!({"type": "string", "description": "Markdown content (for markdown type)"}),
        )
        .property(
            "url",
            json!({"type": "string", "description": "URL (for link type)"}),
        )
        .property(
            "label",
            json!({"type": "string", "description": "Link text (for link type)"}),
        )
        .property(
            "streamId",
            json!({"type": "string", "description": "Stream identifier (for stream type)"}),
        )
        .property(
            "autoplay",
            json!({"type": "boolean", "description": "Auto-play audio (default false)", "default": false}),
        )
        .property(
            "interactive",
            json!({"type": "boolean", "description": "If true, stops turn and waits for user acknowledgment", "default": false}),
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
    /// Handle `image` type — from file path OR inline base64 data.
    ///
    /// Priority: `data` (inline base64) > `path` (file on disk).
    /// Always produces `imageData` + `mimeType` in details for iOS rendering.
    async fn handle_image(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let inline_data = get_optional_string(params, "data");
        let path = get_optional_string(params, "path");

        if let Some(ref b64) = inline_data {
            // Validate that the base64 decodes successfully.
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(b64)
                .map_err(|e| ToolError::Validation {
                    message: format!("Invalid base64 data: {e}"),
                })?;

            let mime = get_optional_string(params, "mimeType")
                .unwrap_or_else(|| "image/png".to_string());

            return Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![
                    crate::core::content::ToolResultContent::text(format!(
                        "Displaying image ({} bytes)",
                        decoded.len()
                    )),
                ]),
                details: Some(json!({
                    "imageData": b64,
                    "mimeType": mime,
                })),
                is_error: None,
                stop_turn: None,
            });
        }

        let path = match path {
            Some(p) => p,
            None => {
                return Ok(error_result(
                    "Missing 'path' or 'data' parameter for image type. \
                     Provide a file path or base64-encoded image data.",
                ))
            }
        };

        let (b64, mime) = self.read_and_encode(&path, SUPPORTED_IMAGE_EXTS, MAX_IMAGE_BYTES, "Image").await?;

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!("Displaying image: {path}")),
            ]),
            details: Some(json!({
                "path": path,
                "imageData": b64,
                "mimeType": mime,
            })),
            is_error: None,
            stop_turn: None,
        })
    }

    /// Handle `images` type — multiple file paths, each encoded to base64.
    async fn handle_images(&self, params: &Value) -> Result<TronToolResult, ToolError> {
        let paths: Vec<String> = params
            .get("paths")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();

        if paths.is_empty() {
            return Ok(error_result(
                "Missing or empty 'paths' array for images type.",
            ));
        }

        let mut images_data: Vec<Value> = Vec::with_capacity(paths.len());
        for path in &paths {
            let (b64, mime) = self
                .read_and_encode(path, SUPPORTED_IMAGE_EXTS, MAX_IMAGE_BYTES, "Image")
                .await?;
            images_data.push(json!({"imageData": b64, "mimeType": mime, "path": path}));
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::text(format!(
                    "Displaying {} images",
                    paths.len()
                )),
            ]),
            details: Some(json!({"images": images_data})),
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

        self.validate_file(&path, SUPPORTED_AUDIO_EXTS, MAX_AUDIO_BYTES, "Audio")?;

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
            None => {
                return Ok(error_result(
                    "Missing 'streamId' parameter for stream type.",
                ))
            }
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

    /// Read a file, validate it, and return `(base64_data, mime_type)`.
    async fn read_and_encode(
        &self,
        path: &str,
        supported_exts: &[&str],
        max_bytes: u64,
        kind: &str,
    ) -> Result<(String, &'static str), ToolError> {
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

        let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
        Ok((b64, mime))
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
    fn schema_has_all_parameters() {
        let tool = DisplayTool::new();
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        for key in &[
            "type", "title", "path", "data", "mimeType", "paths", "content", "url", "label",
            "streamId", "autoplay", "interactive",
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

    // ── Image from path (encodes to base64) ────────────────────

    #[tokio::test]
    async fn image_path_encodes_to_base64() {
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
        assert_eq!(details["mimeType"], "image/png");
        // imageData should be base64 of "fake png data"
        let image_data = details["imageData"].as_str().unwrap();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(image_data)
            .unwrap();
        assert_eq!(decoded, b"fake png data");
    }

    #[tokio::test]
    async fn image_path_jpeg_has_correct_mime() {
        let mut tmp = NamedTempFile::with_suffix(".jpg").unwrap();
        write!(tmp, "jpeg data").unwrap();

        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "path": tmp.path().to_string_lossy().to_string()}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["mimeType"], "image/jpeg");
    }

    // ── Image from inline base64 data ──────────────────────────

    #[tokio::test]
    async fn image_with_data_param() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"inline image bytes");
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "data": b64, "mimeType": "image/jpeg"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.unwrap();
        assert_eq!(details["imageData"], b64);
        assert_eq!(details["mimeType"], "image/jpeg");
    }

    #[tokio::test]
    async fn image_data_defaults_to_png_mime() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"data");
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "image", "data": b64}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["mimeType"], "image/png");
    }

    #[tokio::test]
    async fn image_data_invalid_base64() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "image", "data": "not valid base64!!!"}),
                &make_ctx(),
            )
            .await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("Invalid base64"));
    }

    #[tokio::test]
    async fn image_data_takes_priority_over_path() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"priority data");
        let tool = DisplayTool::new();
        // Both data and path provided — data wins, path ignored.
        let r = tool
            .execute(
                json!({"type": "image", "data": b64, "path": "/nonexistent.png"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert_eq!(r.details.unwrap()["imageData"], b64);
    }

    // ── Image validation edge cases ────────────────────────────

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
    async fn image_no_path_or_data() {
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
    }

    // ── Images (gallery) ───────────────────────────────────────

    #[tokio::test]
    async fn images_encodes_all_to_base64() {
        let mut t1 = NamedTempFile::with_suffix(".jpg").unwrap();
        let mut t2 = NamedTempFile::with_suffix(".png").unwrap();
        write!(t1, "img1").unwrap();
        write!(t2, "img2").unwrap();

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
        let images = details["images"].as_array().unwrap();
        assert_eq!(images.len(), 2);
        assert!(images[0]["imageData"].is_string());
        assert_eq!(images[0]["mimeType"], "image/jpeg");
        assert_eq!(images[1]["mimeType"], "image/png");
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
            .execute(
                json!({"type": "link", "url": "https://example.com"}),
                &make_ctx(),
            )
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
        assert_eq!(r.details.unwrap()["autoplay"], false);
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
        assert_eq!(r.details.unwrap()["autoplay"], true);
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
    }

    // ── Stream ─────────────────────────────────────────────────

    #[tokio::test]
    async fn stream_valid() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(
                json!({"type": "stream", "streamId": "browser-123"}),
                &make_ctx(),
            )
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
        assert_eq!(r.details.unwrap()["title"], "My Title");
    }

    #[tokio::test]
    async fn title_absent_not_in_details() {
        let tool = DisplayTool::new();
        let r = tool
            .execute(json!({"type": "markdown", "content": "text"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.details.unwrap().get("title").is_none());
    }

    #[test]
    fn mime_type_mapping() {
        assert_eq!(mime_for_ext("png"), "image/png");
        assert_eq!(mime_for_ext("jpg"), "image/jpeg");
        assert_eq!(mime_for_ext("jpeg"), "image/jpeg");
        assert_eq!(mime_for_ext("gif"), "image/gif");
        assert_eq!(mime_for_ext("mp3"), "audio/mpeg");
        assert_eq!(mime_for_ext("wav"), "audio/wav");
        assert_eq!(mime_for_ext("unknown"), "application/octet-stream");
    }
}

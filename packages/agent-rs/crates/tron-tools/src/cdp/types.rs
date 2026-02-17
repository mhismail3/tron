//! Browser streaming types.
//!
//! Wire format matches the iOS `BrowserFramePlugin.DataPayload` exactly.

use serde::{Deserialize, Serialize};

/// A single screencast frame delivered to iOS.
///
/// Wire format:
/// ```json
/// {
///   "sessionId": "sess_abc",
///   "data": "<base64-jpeg>",
///   "frameId": 42,
///   "timestamp": 1707999045123,
///   "metadata": { ... }
/// }
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserFrame {
    /// Session this frame belongs to.
    pub session_id: String,
    /// Base64-encoded JPEG image data.
    pub data: String,
    /// Monotonically increasing frame counter.
    pub frame_id: u64,
    /// Unix timestamp in milliseconds.
    pub timestamp: u64,
    /// Viewport metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<FrameMetadata>,
}

/// Viewport metadata for a screencast frame.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameMetadata {
    /// Top offset of the page content.
    pub offset_top: f64,
    /// Device pixel ratio.
    pub page_scale_factor: f64,
    /// Viewport width in device pixels.
    pub device_width: u32,
    /// Viewport height in device pixels.
    pub device_height: u32,
    /// Horizontal scroll offset.
    pub scroll_offset_x: f64,
    /// Vertical scroll offset.
    pub scroll_offset_y: f64,
}

impl Default for FrameMetadata {
    fn default() -> Self {
        Self {
            offset_top: 0.0,
            page_scale_factor: 1.0,
            device_width: 1280,
            device_height: 800,
            scroll_offset_x: 0.0,
            scroll_offset_y: 0.0,
        }
    }
}

/// Screencast configuration options.
#[derive(Clone, Debug)]
pub struct ScreencastOptions {
    /// JPEG quality (0-100).
    pub quality: u32,
    /// Image format.
    pub format: ScreencastFormat,
    /// Maximum capture width.
    pub max_width: u32,
    /// Maximum capture height.
    pub max_height: u32,
    /// Capture every Nth frame (1 = every frame).
    pub every_nth_frame: u32,
}

impl Default for ScreencastOptions {
    fn default() -> Self {
        Self {
            quality: 60,
            format: ScreencastFormat::Jpeg,
            max_width: 1280,
            max_height: 800,
            every_nth_frame: 1,
        }
    }
}

/// Screencast image format.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScreencastFormat {
    /// JPEG format.
    Jpeg,
    /// PNG format.
    Png,
}

impl ScreencastFormat {
    /// CDP protocol string.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Jpeg => "jpeg",
            Self::Png => "png",
        }
    }
}

/// Events emitted by browser sessions on the broadcast channel.
#[derive(Clone, Debug)]
pub enum BrowserEvent {
    /// A screencast frame is ready.
    Frame {
        /// Session this frame belongs to.
        session_id: String,
        /// The frame data.
        frame: BrowserFrame,
    },
    /// A browser session was closed.
    Closed {
        /// Session that was closed.
        session_id: String,
    },
}

/// Status of a browser session.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserStatus {
    /// Whether a browser instance exists for this session.
    pub has_browser: bool,
    /// Whether screencast streaming is active.
    pub is_streaming: bool,
    /// Current page URL (if any).
    pub current_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_frame_serializes_to_ios_wire_format() {
        let frame = BrowserFrame {
            session_id: "sess_abc".into(),
            data: "AQID".into(),
            frame_id: 42,
            timestamp: 1707999045123,
            metadata: Some(FrameMetadata::default()),
        };
        let json = serde_json::to_value(&frame).unwrap();
        assert_eq!(json["sessionId"], "sess_abc");
        assert_eq!(json["data"], "AQID");
        assert_eq!(json["frameId"], 42);
        assert_eq!(json["timestamp"], 1707999045123u64);
        assert!(json["metadata"].is_object());
    }

    #[test]
    fn browser_frame_data_is_base64_string() {
        let frame = BrowserFrame {
            session_id: "s1".into(),
            data: "/9j/4AAQ".into(),
            frame_id: 1,
            timestamp: 0,
            metadata: None,
        };
        let json = serde_json::to_value(&frame).unwrap();
        assert!(json["data"].is_string());
    }

    #[test]
    fn browser_frame_frame_id_is_integer() {
        let frame = BrowserFrame {
            session_id: "s1".into(),
            data: "AA==".into(),
            frame_id: 99,
            timestamp: 0,
            metadata: None,
        };
        let json = serde_json::to_value(&frame).unwrap();
        assert!(json["frameId"].is_number());
        assert_eq!(json["frameId"], 99);
    }

    #[test]
    fn browser_frame_timestamp_is_number() {
        let frame = BrowserFrame {
            session_id: "s1".into(),
            data: "AA==".into(),
            frame_id: 1,
            timestamp: 1707999045123,
            metadata: None,
        };
        let json = serde_json::to_value(&frame).unwrap();
        assert!(json["timestamp"].is_number());
    }

    #[test]
    fn frame_metadata_serializes_all_fields() {
        let meta = FrameMetadata {
            offset_top: 10.0,
            page_scale_factor: 2.0,
            device_width: 1920,
            device_height: 1080,
            scroll_offset_x: 5.0,
            scroll_offset_y: 100.0,
        };
        let json = serde_json::to_value(&meta).unwrap();
        assert_eq!(json["offsetTop"], 10.0);
        assert_eq!(json["pageScaleFactor"], 2.0);
        assert_eq!(json["deviceWidth"], 1920);
        assert_eq!(json["deviceHeight"], 1080);
        assert_eq!(json["scrollOffsetX"], 5.0);
        assert_eq!(json["scrollOffsetY"], 100.0);
    }

    #[test]
    fn frame_metadata_optional_fields_omitted_when_none() {
        let frame = BrowserFrame {
            session_id: "s1".into(),
            data: "AA==".into(),
            frame_id: 1,
            timestamp: 0,
            metadata: None,
        };
        let json = serde_json::to_value(&frame).unwrap();
        assert!(json.get("metadata").is_none());
    }

    #[test]
    fn frame_metadata_default_values() {
        let meta = FrameMetadata::default();
        assert_eq!(meta.device_width, 1280);
        assert_eq!(meta.device_height, 800);
        assert!((meta.page_scale_factor - 1.0).abs() < f64::EPSILON);
        assert!((meta.offset_top - 0.0).abs() < f64::EPSILON);
        assert!((meta.scroll_offset_x - 0.0).abs() < f64::EPSILON);
        assert!((meta.scroll_offset_y - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn screencast_options_default() {
        let opts = ScreencastOptions::default();
        assert_eq!(opts.quality, 60);
        assert_eq!(opts.format, ScreencastFormat::Jpeg);
        assert_eq!(opts.max_width, 1280);
        assert_eq!(opts.max_height, 800);
        assert_eq!(opts.every_nth_frame, 1);
    }

    #[test]
    fn screencast_options_custom() {
        let opts = ScreencastOptions {
            quality: 80,
            format: ScreencastFormat::Png,
            max_width: 1920,
            max_height: 1080,
            every_nth_frame: 2,
        };
        assert_eq!(opts.quality, 80);
        assert_eq!(opts.format, ScreencastFormat::Png);
        assert_eq!(opts.max_width, 1920);
        assert_eq!(opts.max_height, 1080);
        assert_eq!(opts.every_nth_frame, 2);
    }

    #[test]
    fn browser_event_frame_contains_session_id() {
        let event = BrowserEvent::Frame {
            session_id: "s1".into(),
            frame: BrowserFrame {
                session_id: "s1".into(),
                data: "AA==".into(),
                frame_id: 1,
                timestamp: 0,
                metadata: None,
            },
        };
        match event {
            BrowserEvent::Frame { session_id, .. } => assert_eq!(session_id, "s1"),
            _ => panic!("expected Frame"),
        }
    }

    #[test]
    fn browser_event_closed_contains_session_id() {
        let event = BrowserEvent::Closed {
            session_id: "s2".into(),
        };
        match event {
            BrowserEvent::Closed { session_id } => assert_eq!(session_id, "s2"),
            _ => panic!("expected Closed"),
        }
    }

    #[test]
    fn browser_status_default() {
        let status = BrowserStatus::default();
        assert!(!status.has_browser);
        assert!(!status.is_streaming);
        assert!(status.current_url.is_none());
    }

    #[test]
    fn screencast_format_as_str() {
        assert_eq!(ScreencastFormat::Jpeg.as_str(), "jpeg");
        assert_eq!(ScreencastFormat::Png.as_str(), "png");
    }

    #[test]
    fn browser_frame_roundtrip() {
        let frame = BrowserFrame {
            session_id: "s1".into(),
            data: "/9j/4AAQ".into(),
            frame_id: 42,
            timestamp: 1707999045123,
            metadata: Some(FrameMetadata::default()),
        };
        let json = serde_json::to_string(&frame).unwrap();
        let decoded: BrowserFrame = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.session_id, "s1");
        assert_eq!(decoded.frame_id, 42);
        assert_eq!(decoded.timestamp, 1707999045123);
    }

    #[test]
    fn browser_status_serializes_camel_case() {
        let status = BrowserStatus {
            has_browser: true,
            is_streaming: true,
            current_url: Some("https://example.com".into()),
        };
        let json = serde_json::to_value(&status).unwrap();
        assert_eq!(json["hasBrowser"], true);
        assert_eq!(json["isStreaming"], true);
        assert_eq!(json["currentUrl"], "https://example.com");
    }
}

//! UI/TUI appearance settings.
//!
//! Configuration for colors, icons, animations, and input behavior.
//! These are primarily used by the TUI frontend but stored in the shared
//! settings file.

use serde::{Deserialize, Serialize};

/// UI settings container.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UiSettings {
    /// Active theme name.
    pub theme: String,
    /// Color palette.
    pub palette: PaletteSettings,
    /// Unicode icon characters.
    pub icons: IconSettings,
    /// Thinking animation settings.
    pub thinking_animation: ThinkingAnimationSettings,
    /// Input behavior settings.
    pub input: InputSettings,
    /// Menu display settings.
    pub menu: MenuSettings,
}

impl Default for UiSettings {
    fn default() -> Self {
        Self {
            theme: "forest_green".to_string(),
            palette: PaletteSettings::default(),
            icons: IconSettings::default(),
            thinking_animation: ThinkingAnimationSettings::default(),
            input: InputSettings::default(),
            menu: MenuSettings::default(),
        }
    }
}

/// Color palette (20 named colors).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PaletteSettings {
    /// Primary brand color.
    pub primary: String,
    /// Lighter primary variant.
    pub primary_light: String,
    /// Bright primary variant.
    pub primary_bright: String,
    /// Vivid primary variant.
    pub primary_vivid: String,
    /// Emerald accent.
    pub emerald: String,
    /// Mint accent.
    pub mint: String,
    /// Sage accent.
    pub sage: String,
    /// Dark background.
    pub dark: String,
    /// Muted background.
    pub muted: String,
    /// Subtle background.
    pub subtle: String,
    /// Bright text.
    pub text_bright: String,
    /// Primary text.
    pub text_primary: String,
    /// Secondary text.
    pub text_secondary: String,
    /// Muted text.
    pub text_muted: String,
    /// Dim text.
    pub text_dim: String,
    /// Status bar text color.
    pub status_bar_text: String,
    /// Success indicator.
    pub success: String,
    /// Warning indicator.
    pub warning: String,
    /// Error indicator.
    pub error: String,
    /// Info indicator.
    pub info: String,
}

impl Default for PaletteSettings {
    fn default() -> Self {
        Self {
            primary: "#123524".to_string(),
            primary_light: "#1a4a32".to_string(),
            primary_bright: "#2d7a4e".to_string(),
            primary_vivid: "#34d399".to_string(),
            emerald: "#10b981".to_string(),
            mint: "#6ee7b7".to_string(),
            sage: "#86efac".to_string(),
            dark: "#0a1f15".to_string(),
            muted: "#1f3d2c".to_string(),
            subtle: "#2d5a40".to_string(),
            text_bright: "#ecfdf5".to_string(),
            text_primary: "#d1fae5".to_string(),
            text_secondary: "#a7f3d0".to_string(),
            text_muted: "#6b8f7a".to_string(),
            text_dim: "#4a6b58".to_string(),
            status_bar_text: "#2eb888".to_string(),
            success: "#22c55e".to_string(),
            warning: "#f59e0b".to_string(),
            error: "#ef4444".to_string(),
            info: "#38bdf8".to_string(),
        }
    }
}

/// Unicode icon characters.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IconSettings {
    /// Prompt indicator.
    pub prompt: String,
    /// User message indicator.
    pub user: String,
    /// Assistant message indicator.
    pub assistant: String,
    /// System message indicator.
    pub system: String,
    /// Tool running indicator.
    pub tool_running: String,
    /// Tool success indicator.
    pub tool_success: String,
    /// Tool error indicator.
    pub tool_error: String,
    /// Ready state indicator.
    pub ready: String,
    /// Thinking state indicator.
    pub thinking: String,
    /// Streaming state indicator.
    pub streaming: String,
    /// Bullet point character.
    pub bullet: String,
    /// Arrow character.
    pub arrow: String,
    /// Check mark character.
    pub check: String,
    /// Paste block opening character.
    pub paste_open: String,
    /// Paste block closing character.
    pub paste_close: String,
}

impl Default for IconSettings {
    fn default() -> Self {
        Self {
            prompt: "\u{203a}".to_string(),
            user: "\u{203a}".to_string(),
            assistant: "\u{25c6}".to_string(),
            system: "\u{25c7}".to_string(),
            tool_running: "\u{25c7}".to_string(),
            tool_success: "\u{25c6}".to_string(),
            tool_error: "\u{25c8}".to_string(),
            ready: "\u{25c6}".to_string(),
            thinking: "\u{25c7}".to_string(),
            streaming: "\u{25c6}".to_string(),
            bullet: "\u{2022}".to_string(),
            arrow: "\u{2192}".to_string(),
            check: "\u{2713}".to_string(),
            paste_open: "\u{2308}".to_string(),
            paste_close: "\u{230b}".to_string(),
        }
    }
}

/// Thinking animation settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ThinkingAnimationSettings {
    /// Animation frame characters.
    pub chars: Vec<String>,
    /// Number of visible animation slots.
    pub width: usize,
    /// Frame interval in milliseconds.
    pub interval_ms: u64,
}

impl Default for ThinkingAnimationSettings {
    fn default() -> Self {
        Self {
            chars: vec![
                "\u{2581}".to_string(),
                "\u{2582}".to_string(),
                "\u{2583}".to_string(),
                "\u{2584}".to_string(),
                "\u{2585}".to_string(),
            ],
            width: 4,
            interval_ms: 120,
        }
    }
}

/// Input behavior settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InputSettings {
    /// Character threshold to detect paste vs typing.
    pub paste_threshold: usize,
    /// Maximum history entries to retain.
    pub max_history: usize,
    /// Default terminal width in columns.
    pub default_terminal_width: usize,
    /// Column threshold for narrow mode.
    pub narrow_threshold: usize,
    /// Visible input lines in narrow mode.
    pub narrow_visible_lines: usize,
    /// Visible input lines in normal mode.
    pub normal_visible_lines: usize,
}

impl Default for InputSettings {
    fn default() -> Self {
        Self {
            paste_threshold: 3,
            max_history: 100,
            default_terminal_width: 80,
            narrow_threshold: 50,
            narrow_visible_lines: 10,
            normal_visible_lines: 20,
        }
    }
}

/// Menu display settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MenuSettings {
    /// Maximum visible commands in the menu.
    pub max_visible_commands: usize,
}

impl Default for MenuSettings {
    fn default() -> Self {
        Self {
            max_visible_commands: 5,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palette_defaults() {
        let p = PaletteSettings::default();
        assert_eq!(p.primary, "#123524");
        assert_eq!(p.error, "#ef4444");
        assert_eq!(p.info, "#38bdf8");
    }

    #[test]
    fn palette_serde_camel_case() {
        let p = PaletteSettings::default();
        let json = serde_json::to_value(&p).unwrap();
        assert!(json.get("primaryLight").is_some());
        assert!(json.get("textBright").is_some());
        assert!(json.get("statusBarText").is_some());
    }

    #[test]
    fn icons_defaults() {
        let i = IconSettings::default();
        assert_eq!(i.prompt, "\u{203a}");
        assert_eq!(i.assistant, "\u{25c6}");
        assert_eq!(i.bullet, "\u{2022}");
        assert_eq!(i.check, "\u{2713}");
    }

    #[test]
    fn thinking_animation_defaults() {
        let t = ThinkingAnimationSettings::default();
        assert_eq!(t.chars.len(), 5);
        assert_eq!(t.width, 4);
        assert_eq!(t.interval_ms, 120);
    }

    #[test]
    fn input_defaults() {
        let i = InputSettings::default();
        assert_eq!(i.paste_threshold, 3);
        assert_eq!(i.max_history, 100);
        assert_eq!(i.default_terminal_width, 80);
    }

    #[test]
    fn menu_defaults() {
        let m = MenuSettings::default();
        assert_eq!(m.max_visible_commands, 5);
    }

    #[test]
    fn ui_theme_default() {
        let ui = UiSettings::default();
        assert_eq!(ui.theme, "forest_green");
    }

    #[test]
    fn ui_partial_json() {
        let json = serde_json::json!({
            "theme": "midnight",
            "palette": {
                "primary": "#ff0000"
            }
        });
        let ui: UiSettings = serde_json::from_value(json).unwrap();
        assert_eq!(ui.theme, "midnight");
        assert_eq!(ui.palette.primary, "#ff0000");
        // Other palette fields should be defaults
        assert_eq!(ui.palette.error, "#ef4444");
        // Other sections should be defaults
        assert_eq!(ui.icons.prompt, "\u{203a}");
    }
}

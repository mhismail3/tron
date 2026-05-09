//! Rust-native input driver for macOS using the `enigo` crate.
//!
//! Wraps `CGEvent`-based mouse and keyboard operations in async methods.
//! All operations work from backgrounded processes (ppid=1) because they
//! use `CoreGraphics` `CGEvent` APIs directly, not osascript System Events.
//!
//! Each async method spawns a blocking task with a fresh `Enigo` instance
//! to avoid Send/Sync issues across the tokio runtime.

use enigo::{
    Axis, Button, Coordinate, Direction, Enigo, InputResult, Key, Keyboard, Mouse, Settings,
};

/// Map a key name string to an enigo `Key`.
///
/// Supports modifiers (cmd, ctrl, alt, shift), special keys (enter, tab,
/// escape, space, delete, arrows), and single characters.
pub fn map_key(name: &str) -> Option<Key> {
    let lower = name.to_lowercase();
    match lower.as_str() {
        "cmd" | "command" => Some(Key::Meta),
        "ctrl" | "control" => Some(Key::Control),
        "alt" | "option" => Some(Key::Alt),
        "shift" => Some(Key::Shift),
        "enter" | "return" => Some(Key::Return),
        "tab" => Some(Key::Tab),
        "escape" | "esc" => Some(Key::Escape),
        "space" => Some(Key::Space),
        "delete" | "backspace" => Some(Key::Backspace),
        "up" => Some(Key::UpArrow),
        "down" => Some(Key::DownArrow),
        "left" => Some(Key::LeftArrow),
        "right" => Some(Key::RightArrow),
        "home" => Some(Key::Home),
        "end" => Some(Key::End),
        "pageup" => Some(Key::PageUp),
        "pagedown" => Some(Key::PageDown),
        "capslock" => Some(Key::CapsLock),
        "f1" => Some(Key::F1),
        "f2" => Some(Key::F2),
        "f3" => Some(Key::F3),
        "f4" => Some(Key::F4),
        "f5" => Some(Key::F5),
        "f6" => Some(Key::F6),
        "f7" => Some(Key::F7),
        "f8" => Some(Key::F8),
        "f9" => Some(Key::F9),
        "f10" => Some(Key::F10),
        "f11" => Some(Key::F11),
        "f12" => Some(Key::F12),
        _ if name.len() == 1 => {
            // Preserve original case for Unicode chars (a vs A matters)
            name.chars().next().map(Key::Unicode)
        }
        _ => None,
    }
}

/// Whether a key name is a modifier (cmd, ctrl, alt, shift).
pub fn is_modifier(name: &str) -> bool {
    matches!(
        name.to_lowercase().as_str(),
        "cmd" | "command" | "ctrl" | "control" | "alt" | "option" | "shift"
    )
}

fn fmt_err(e: impl std::fmt::Display) -> String {
    format!("{e}")
}

fn input_err(r: InputResult<()>) -> Result<(), String> {
    r.map_err(fmt_err)
}

fn make_enigo() -> Result<Enigo, String> {
    Enigo::new(&Settings {
        open_prompt_to_get_permissions: true,
        independent_of_keyboard_state: true,
        ..Settings::default()
    })
    .map_err(fmt_err)
}

/// Click at absolute screen coordinates.
pub async fn click(x: f64, y: f64, button_name: &str, count: u64) -> Result<(), String> {
    let xi = x as i32;
    let yi = y as i32;
    let btn_name = button_name.to_string();
    let count = count.max(1);

    tokio::task::spawn_blocking(move || {
        let mut enigo = make_enigo()?;
        let button = match btn_name.as_str() {
            "right" => Button::Right,
            "middle" => Button::Middle,
            _ => Button::Left,
        };

        // Move to target position
        input_err(enigo.move_mouse(xi, yi, Coordinate::Abs))?;

        // Perform click(s)
        for _ in 0..count {
            input_err(enigo.button(button, Direction::Click))?;
        }

        Ok(())
    })
    .await
    .map_err(fmt_err)?
}

/// Type a text string using `CGEvent` unicode input.
pub async fn type_text(text: &str) -> Result<(), String> {
    let text = text.to_string();

    tokio::task::spawn_blocking(move || {
        let mut enigo = make_enigo()?;
        input_err(enigo.text(&text))
    })
    .await
    .map_err(fmt_err)?
}

/// Press a key combination (e.g., `["cmd", "c"]` → Cmd+C).
///
/// Modifiers are pressed first, the main key is clicked, then modifiers released.
pub async fn key_press(keys: &[String]) -> Result<(), String> {
    let keys: Vec<String> = keys.to_vec();

    tokio::task::spawn_blocking(move || {
        let mut enigo = make_enigo()?;

        let mut modifiers = Vec::new();
        let mut main_keys = Vec::new();

        for k in &keys {
            if is_modifier(k) {
                if let Some(key) = map_key(k) {
                    modifiers.push(key);
                }
            } else if let Some(key) = map_key(k) {
                main_keys.push(key);
            } else {
                return Err(format!("Unknown key: {k}"));
            }
        }

        // Press modifiers
        for m in &modifiers {
            input_err(enigo.key(*m, Direction::Press))?;
        }

        // Click main key(s)
        if main_keys.is_empty() && !modifiers.is_empty() {
            // Only modifiers (e.g., just "shift") — press and release
            // Already pressed above, will be released below
        } else {
            for k in &main_keys {
                input_err(enigo.key(*k, Direction::Click))?;
            }
        }

        // Release modifiers in reverse order
        for m in modifiers.iter().rev() {
            input_err(enigo.key(*m, Direction::Release))?;
        }

        Ok(())
    })
    .await
    .map_err(fmt_err)?
}

/// Scroll at a position.
pub async fn scroll(direction: &str, amount: i32, x: f64, y: f64) -> Result<(), String> {
    let xi = x as i32;
    let yi = y as i32;
    let dir = direction.to_string();
    // Convert pixel amount to scroll units (enigo uses 15-degree wheel rotations)
    let scroll_units = (amount / 15).max(1);

    tokio::task::spawn_blocking(move || {
        let mut enigo = make_enigo()?;

        // Move to scroll position first
        if xi != 0 || yi != 0 {
            input_err(enigo.move_mouse(xi, yi, Coordinate::Abs))?;
        }

        let (length, axis) = match dir.as_str() {
            "up" => (-scroll_units, Axis::Vertical),
            "down" => (scroll_units, Axis::Vertical),
            "left" => (-scroll_units, Axis::Horizontal),
            "right" => (scroll_units, Axis::Horizontal),
            _ => return Err(format!("Unknown scroll direction: {dir}")),
        };

        input_err(enigo.scroll(length, axis))
    })
    .await
    .map_err(fmt_err)?
}

/// Move the mouse cursor to absolute screen coordinates.
pub async fn move_mouse(x: f64, y: f64) -> Result<(), String> {
    let xi = x as i32;
    let yi = y as i32;

    tokio::task::spawn_blocking(move || {
        let mut enigo = make_enigo()?;
        input_err(enigo.move_mouse(xi, yi, Coordinate::Abs))
    })
    .await
    .map_err(fmt_err)?
}

/// Get screen dimensions (width, height) in logical points.
pub async fn screen_size() -> Result<(i32, i32), String> {
    tokio::task::spawn_blocking(|| {
        let enigo = make_enigo()?;
        enigo.main_display().map_err(fmt_err)
    })
    .await
    .map_err(fmt_err)?
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Key mapping tests ──

    #[test]
    fn map_key_cmd_variants() {
        assert_eq!(map_key("cmd"), Some(Key::Meta));
        assert_eq!(map_key("command"), Some(Key::Meta));
        assert_eq!(map_key("Cmd"), Some(Key::Meta));
        assert_eq!(map_key("COMMAND"), Some(Key::Meta));
    }

    #[test]
    fn map_key_ctrl_variants() {
        assert_eq!(map_key("ctrl"), Some(Key::Control));
        assert_eq!(map_key("control"), Some(Key::Control));
        assert_eq!(map_key("Ctrl"), Some(Key::Control));
    }

    #[test]
    fn map_key_alt_variants() {
        assert_eq!(map_key("alt"), Some(Key::Alt));
        assert_eq!(map_key("option"), Some(Key::Alt));
        assert_eq!(map_key("Alt"), Some(Key::Alt));
    }

    #[test]
    fn map_key_shift() {
        assert_eq!(map_key("shift"), Some(Key::Shift));
        assert_eq!(map_key("Shift"), Some(Key::Shift));
    }

    #[test]
    fn map_key_special_keys() {
        assert_eq!(map_key("enter"), Some(Key::Return));
        assert_eq!(map_key("return"), Some(Key::Return));
        assert_eq!(map_key("tab"), Some(Key::Tab));
        assert_eq!(map_key("escape"), Some(Key::Escape));
        assert_eq!(map_key("esc"), Some(Key::Escape));
        assert_eq!(map_key("space"), Some(Key::Space));
        assert_eq!(map_key("delete"), Some(Key::Backspace));
        assert_eq!(map_key("backspace"), Some(Key::Backspace));
    }

    #[test]
    fn map_key_arrows() {
        assert_eq!(map_key("up"), Some(Key::UpArrow));
        assert_eq!(map_key("down"), Some(Key::DownArrow));
        assert_eq!(map_key("left"), Some(Key::LeftArrow));
        assert_eq!(map_key("right"), Some(Key::RightArrow));
    }

    #[test]
    fn map_key_navigation() {
        assert_eq!(map_key("home"), Some(Key::Home));
        assert_eq!(map_key("end"), Some(Key::End));
        assert_eq!(map_key("pageup"), Some(Key::PageUp));
        assert_eq!(map_key("pagedown"), Some(Key::PageDown));
    }

    #[test]
    fn map_key_function_keys() {
        assert_eq!(map_key("f1"), Some(Key::F1));
        assert_eq!(map_key("f5"), Some(Key::F5));
        assert_eq!(map_key("f12"), Some(Key::F12));
    }

    #[test]
    fn map_key_single_char() {
        assert_eq!(map_key("a"), Some(Key::Unicode('a')));
        assert_eq!(map_key("z"), Some(Key::Unicode('z')));
        assert_eq!(map_key("A"), Some(Key::Unicode('A'))); // preserves case for Unicode
    }

    #[test]
    fn map_key_unknown() {
        assert_eq!(map_key("superduperkey"), None);
        assert_eq!(map_key("cmd+c"), None); // multi-char, not a known key
        assert_eq!(map_key(""), None);
    }

    #[test]
    fn is_modifier_true() {
        assert!(is_modifier("cmd"));
        assert!(is_modifier("command"));
        assert!(is_modifier("ctrl"));
        assert!(is_modifier("control"));
        assert!(is_modifier("alt"));
        assert!(is_modifier("option"));
        assert!(is_modifier("shift"));
        assert!(is_modifier("Cmd")); // case insensitive
    }

    #[test]
    fn is_modifier_false() {
        assert!(!is_modifier("enter"));
        assert!(!is_modifier("a"));
        assert!(!is_modifier("space"));
        assert!(!is_modifier("f1"));
    }

    // Note: we cannot test actual enigo operations in unit tests because they
    // require a display and would actually move the mouse/type/etc. Those are
    // verified in the manual integration tests described in the verification section.
}

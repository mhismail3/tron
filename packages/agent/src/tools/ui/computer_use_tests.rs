use super::*;
use crate::tools::testutil::{extract_text, make_ctx};
use crate::tools::traits::ProcessOutput;

/// Mock runner that captures commands and returns configurable output.
struct MockRunner {
    handler: Box<dyn Fn(&str) -> ProcessOutput + Send + Sync>,
}

impl MockRunner {
    fn success(stdout: &str) -> Self {
        let s = stdout.to_string();
        Self {
            handler: Box::new(move |_| ProcessOutput {
                stdout: s.clone(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }),
        }
    }

    fn failing(stderr: &str) -> Self {
        let s = stderr.to_string();
        Self {
            handler: Box::new(move |_| ProcessOutput {
                stdout: String::new(),
                stderr: s.clone(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }),
        }
    }

    /// Runner that responds differently based on command content.
    fn with_handler<F>(handler: F) -> Self
    where
        F: Fn(&str) -> ProcessOutput + Send + Sync + 'static,
    {
        Self {
            handler: Box::new(handler),
        }
    }
}

#[async_trait]
impl ProcessRunner for MockRunner {
    async fn run_command(
        &self,
        command: &str,
        _opts: &ProcessOptions,
    ) -> Result<ProcessOutput, ToolError> {
        Ok((self.handler)(command))
    }
}

fn tool(confirm: bool) -> ComputerUseTool {
    configure_test_tool(ComputerUseTool::new(
        Arc::new(MockRunner::success("")),
        confirm,
        500,
    ))
}

fn tool_with_runner(runner: MockRunner, confirm: bool) -> ComputerUseTool {
    configure_test_tool(ComputerUseTool::new(Arc::new(runner), confirm, 500))
}

#[cfg(target_os = "macos")]
fn configure_test_tool(mut tool: ComputerUseTool) -> ComputerUseTool {
    tool.use_native_input = false;
    tool
}

#[cfg(not(target_os = "macos"))]
fn configure_test_tool(tool: ComputerUseTool) -> ComputerUseTool {
    tool
}

// ─── Schema tests ───

#[test]
fn schema_has_action_parameter() {
    let t = tool(true);
    let def = t.definition();
    assert_eq!(def.name, "ComputerUse");
    let props = def.parameters.properties.unwrap();
    assert!(props.contains_key("action"));
    let required = def.parameters.required.unwrap();
    assert!(required.contains(&"action".into()));
}

#[test]
fn schema_action_enum_values() {
    let t = tool(true);
    let def = t.definition();
    let props = def.parameters.properties.unwrap();
    let action = &props["action"];
    let enum_values = action["enum"].as_array().unwrap();
    for expected in [
        "screenshot",
        "clickElement",
        "listElements",
        "type",
        "keypress",
        "scroll",
        "getWindows",
        "focusWindow",
    ] {
        assert!(
            enum_values.contains(&json!(expected)),
            "missing: {expected}"
        );
    }
}

#[test]
fn schema_has_confirmed_property() {
    let t = tool(true);
    let def = t.definition();
    let props = def.parameters.properties.unwrap();
    assert!(
        props.contains_key("confirmed"),
        "should have confirmed property for confirmation bypass"
    );
}

#[test]
fn schema_has_region_property() {
    let t = tool(true);
    let def = t.definition();
    let props = def.parameters.properties.unwrap();
    assert!(
        props.contains_key("region"),
        "should have region property for area screenshots"
    );
    let region = &props["region"];
    assert_eq!(region["type"], "object");
    let region_props = region["properties"].as_object().unwrap();
    assert!(region_props.contains_key("x"));
    assert!(region_props.contains_key("y"));
    assert!(region_props.contains_key("width"));
    assert!(region_props.contains_key("height"));
}

#[test]
fn serialized_execution_mode() {
    let t = tool(true);
    assert_eq!(
        t.execution_mode(),
        crate::tools::traits::ExecutionMode::Serialized("computer_use".into())
    );
}

#[test]
fn screenshot_action_no_required_params() {
    let t = tool(false);
    let def = t.definition();
    let required = def.parameters.required.unwrap();
    assert_eq!(required.len(), 1);
    assert_eq!(required[0], "action");
}

// ─── Confirmation gating tests ───

#[tokio::test]
async fn mutating_action_requires_confirmation_when_enabled() {
    let t = tool(true);
    for action in MUTATING_ACTIONS {
        let mut params = json!({"action": action});
        // Add required params for each action
        match *action {
            "click" | "moveMouse" => {
                params["x"] = json!(100);
                params["y"] = json!(200);
            }
            "type" => {
                params["text"] = json!("hello");
            }
            "keypress" => {
                params["keys"] = json!(["enter"]);
            }
            _ => {}
        }
        let r = t.execute(params, &make_ctx()).await.unwrap();
        assert_eq!(
            r.is_error,
            Some(true),
            "action '{action}' should require confirmation"
        );
        assert!(
            extract_text(&r).contains("requires confirmation"),
            "action '{action}' error should mention confirmation"
        );
    }
}

#[tokio::test]
async fn mutating_action_proceeds_with_confirmed_flag() {
    let t = tool(true);
    let r = t
        .execute(
            json!({"action": "type", "text": "hello", "confirmed": true}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should proceed when confirmed=true");
}

#[tokio::test]
async fn mutating_action_proceeds_when_confirmation_disabled() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "type", "text": "hello"}), &make_ctx())
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "should proceed when confirm_before_action=false"
    );
}

#[tokio::test]
async fn readonly_actions_skip_confirmation() {
    let t = tool(true);
    // screenshot is read-only
    // Note: screenshot will fail with mock since there's no file, but it shouldn't hit confirmation
    let r = t
        .execute(json!({"action": "getWindows"}), &make_ctx())
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "getWindows should not require confirmation"
    );
}

// ─── Action tests ───

#[tokio::test]
async fn unknown_action_returns_error() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "dance"}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("Unknown action"));
}

#[tokio::test]
async fn missing_action_returns_error() {
    let t = tool(false);
    let r = t.execute(json!({}), &make_ctx()).await.unwrap();
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn type_text() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "type", "text": "hello world"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    let text = extract_text(&r);
    assert!(text.contains("Typed 11 characters"));
}

#[tokio::test]
async fn type_requires_text() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "type"}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn type_special_characters() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "type", "text": "hello \"world\" & 'test'"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
}

#[tokio::test]
async fn type_unicode() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "type", "text": "café résumé 日本語"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
}

#[tokio::test]
async fn keypress_enter() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "keypress", "keys": ["enter"]}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("Pressed: enter"));
}

#[tokio::test]
async fn keypress_cmd_c() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "keypress", "keys": ["cmd", "c"]}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("Pressed: cmd+c"));
}

#[tokio::test]
async fn keypress_multi_modifier() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "keypress", "keys": ["cmd", "shift", "s"]}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("Pressed: cmd+shift+s"));
}

#[tokio::test]
async fn keypress_invalid_key() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "keypress", "keys": ["superduperkey"]}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("Unknown key"));
}

#[tokio::test]
async fn keypress_empty_keys() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "keypress", "keys": []}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn get_windows_returns_list() {
    let t = tool_with_runner(
        MockRunner::success("Safari | Google | 0,0 | 1920,1080 | visible\n"),
        false,
    );
    let r = t
        .execute(json!({"action": "getWindows"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    let text = extract_text(&r);
    assert!(text.contains("Safari"), "should list Safari: {text}");
    assert!(
        text.contains("Status"),
        "header should include Status column: {text}"
    );
}

#[tokio::test]
async fn get_windows_includes_visibility_status() {
    let t = tool_with_runner(
        MockRunner::success(
            "Safari | Google | 0,0 | 1920,1080 | visible\nTextEdit | Untitled | 100,100 | 800,600 | off-screen\n",
        ),
        false,
    );
    let r = t
        .execute(json!({"action": "getWindows"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    let text = extract_text(&r);
    assert!(
        text.contains("visible"),
        "should show visible state: {text}"
    );
    assert!(
        text.contains("off-screen"),
        "should show off-screen state: {text}"
    );
}

#[tokio::test]
async fn get_windows_empty() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "getWindows"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("No windows found"));
}

#[tokio::test]
async fn focus_window_by_title() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Safari\tApple\t12345\tactivated\ttrue".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("Focused window: Safari"));
}

#[tokio::test]
async fn focus_window_not_found() {
    let t = tool_with_runner(MockRunner::failing("not found"), false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "NonExistent"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(
        text.contains("not found"),
        "error should mention not found: {text}"
    );
}

#[tokio::test]
async fn focus_window_requires_window_param() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "focusWindow"}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn scroll_down() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "scroll", "x": 500, "y": 500, "direction": "down", "amount": 200}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("Scrolled down"));
}

#[tokio::test]
async fn scroll_invalid_direction() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "scroll", "direction": "diagonal"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn scroll_defaults_to_down() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "scroll"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none());
    assert!(extract_text(&r).contains("Scrolled down"));
}

// ─── Screenshot throttle tests ───

#[tokio::test]
async fn screenshot_throttle_blocks_rapid_calls() {
    // Use a runner that returns a valid PNG-ish file for screenshots
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("screencapture") {
            // Create a tiny fake file at the path
            // The actual file creation is handled by the runner, but in tests
            // the file won't exist. The tool will fail at read, which is fine
            // for throttle testing.
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });

    let t = ComputerUseTool::new(Arc::new(runner), false, 500);

    // Simulate that a screenshot was just taken
    t.last_screenshot_ms
        .store(ComputerUseTool::now_ms(), Ordering::Relaxed);

    // Immediate second call should be throttled
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("throttled"));
}

#[tokio::test]
async fn screenshot_throttle_allows_after_interval() {
    let t = ComputerUseTool::new(Arc::new(MockRunner::success("")), false, 500);

    // Set last screenshot to well in the past
    let past = ComputerUseTool::now_ms() - 1000;
    t.last_screenshot_ms.store(past, Ordering::Relaxed);

    // This call should NOT be throttled (but will fail at file read, which is OK)
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    // It shouldn't be a throttle error (it may fail for other reasons in test env)
    if r.is_error == Some(true) {
        assert!(!extract_text(&r).contains("throttled"));
    }
}

#[tokio::test]
async fn screenshot_custom_throttle_value() {
    let t = ComputerUseTool::new(Arc::new(MockRunner::success("")), false, 2000);

    // Set last screenshot to 1 second ago — should still be throttled with 2000ms setting
    let past = ComputerUseTool::now_ms() - 1000;
    t.last_screenshot_ms.store(past, Ordering::Relaxed);

    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("throttled"));
}

// ─── Screenshot compression tests ───

/// Helper: create a MockRunner that simulates the full screenshot pipeline.
/// `png_size` controls how many bytes the "PNG" file will be.
/// `jpg_size` controls how many bytes the "JPEG" file will be (None = sips fails).
fn screenshot_runner(png_size: usize, jpg_size: Option<usize>) -> MockRunner {
    MockRunner::with_handler(move |cmd| {
        if cmd.contains("screencapture") {
            let path = cmd.rsplit(' ').next().unwrap_or("/tmp/test.png");
            // Write a fake PNG with valid IHDR header so png_dimensions() works.
            // PNG: 8-byte sig + 4-byte IHDR len + 4-byte "IHDR" + 4-byte W + 4-byte H
            let mut data = Vec::with_capacity(png_size.max(24));
            data.extend_from_slice(b"\x89PNG\r\n\x1a\n"); // PNG signature (8 bytes)
            data.extend_from_slice(&13u32.to_be_bytes()); // IHDR data length (9-12)
            data.extend_from_slice(b"IHDR"); // chunk type (13-16)
            data.extend_from_slice(&1280u32.to_be_bytes()); // width (17-20)
            data.extend_from_slice(&960u32.to_be_bytes()); // height (21-24)
            // Pad to the requested size
            if png_size > data.len() {
                data.resize(png_size, 0);
            }
            std::fs::write(path, &data).ok();
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else if cmd.contains("sips") && cmd.contains("--out") {
            // JPEG conversion step (has --out flag)
            match jpg_size {
                Some(size) => {
                    let out_path = cmd
                        .rfind("--out '")
                        .map(|i| {
                            let start = i + 7;
                            let end = cmd[start..]
                                .find('\'')
                                .map(|j| start + j)
                                .unwrap_or(cmd.len());
                            &cmd[start..end]
                        })
                        .unwrap_or("/tmp/test.jpg");
                    let data = vec![0xFFu8; size];
                    std::fs::write(out_path, &data).ok();
                    ProcessOutput {
                        stdout: String::new(),
                        stderr: String::new(),
                        exit_code: 0,
                        duration_ms: 10,
                        timed_out: false,
                        interrupted: false,
                    }
                }
                None => ProcessOutput {
                    stdout: String::new(),
                    stderr: "sips failed".into(),
                    exit_code: 1,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                },
            }
        } else if cmd.contains("sips") && cmd.contains("resampleHeightWidthMax") {
            // Resize step — succeeds (file already written by screencapture handler)
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    })
}

#[tokio::test]
async fn screenshot_compression_prefers_smaller_format() {
    // JPEG (500 bytes) smaller than PNG (1000 bytes) → use JPEG
    let t = tool_with_runner(screenshot_runner(1000, Some(500)), false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    assert!(text.contains("JPEG"), "text should say JPEG: {text}");
    let d = r.details.unwrap();
    assert_eq!(d["mimeType"], "image/jpeg");
    assert_eq!(d["sizeBytes"], 500);
}

#[tokio::test]
async fn screenshot_compression_skips_larger_jpeg() {
    // JPEG (2000 bytes) LARGER than PNG (1000 bytes) → use PNG
    let t = tool_with_runner(screenshot_runner(1000, Some(2000)), false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    assert!(
        text.contains("bytes PNG"),
        "text should say PNG when JPEG is larger: {text}"
    );
    let d = r.details.unwrap();
    assert_eq!(d["mimeType"], "image/png");
    assert_eq!(d["sizeBytes"], 1000);
}

#[tokio::test]
async fn screenshot_text_has_1to1_mapping() {
    let t = tool_with_runner(screenshot_runner(1000, Some(500)), false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    assert!(text.contains("bytes JPEG"), "should state format: {text}");
    #[cfg(target_os = "macos")]
    assert!(text.contains("1:1"), "should mention 1:1 mapping: {text}");
}

#[tokio::test]
async fn screenshot_window_text_has_position() {
    let runner = window_screenshot_runner("42\ttrue\t1187\t1100\t505\t273", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    // Should include window position for coordinate offset
    assert!(
        text.contains("505"),
        "should include window x position: {text}"
    );
    assert!(
        text.contains("273"),
        "should include window y position: {text}"
    );
    // Details should have windowX/windowY
    let d = r.details.unwrap();
    assert_eq!(d["windowX"], 505);
    assert_eq!(d["windowY"], 273);
}

#[tokio::test]
async fn screenshot_compression_skips_same_size_jpeg() {
    // JPEG same size as PNG → prefer PNG (no benefit from lossy)
    let t = tool_with_runner(screenshot_runner(1000, Some(1000)), false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let d = r.details.unwrap();
    assert_eq!(d["mimeType"], "image/png");
}

#[tokio::test]
async fn screenshot_compression_fallback_on_sips_failure() {
    // sips fails → use PNG
    let t = tool_with_runner(screenshot_runner(1000, None), false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    assert!(
        text.contains("bytes PNG"),
        "text should say PNG on sips failure: {text}"
    );
    let d = r.details.unwrap();
    assert_eq!(d["mimeType"], "image/png");
}

#[tokio::test]
async fn screenshot_compression_empty_jpeg_falls_back() {
    // sips succeeds but produces empty JPEG → use PNG
    let t = tool_with_runner(screenshot_runner(1000, Some(0)), false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let d = r.details.unwrap();
    assert_eq!(d["mimeType"], "image/png");
}

// ─── Region screenshot tests ───

#[tokio::test]
async fn screenshot_region_captures_with_correct_command() {
    use std::sync::{Arc as StdArc, Mutex};
    let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
    let cmds = commands.clone();
    let runner = MockRunner::with_handler(move |cmd| {
        cmds.lock().unwrap().push(cmd.to_string());
        if cmd.contains("screencapture") {
            // Write a fake PNG with valid header
            let path = cmd.rsplit(' ').next().unwrap_or("/tmp/test.png");
            let mut data = Vec::with_capacity(1000);
            data.extend_from_slice(b"\x89PNG\r\n\x1a\n");
            data.extend_from_slice(&13u32.to_be_bytes());
            data.extend_from_slice(b"IHDR");
            data.extend_from_slice(&400u32.to_be_bytes());
            data.extend_from_slice(&300u32.to_be_bytes());
            data.resize(1000, 0);
            std::fs::write(path, &data).ok();
        }
        ProcessOutput {
            stdout: String::new(),
            stderr: String::new(),
            exit_code: 0,
            duration_ms: 10,
            timed_out: false,
            interrupted: false,
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({
                "action": "screenshot",
                "region": {"x": 100, "y": 200, "width": 400, "height": 300}
            }),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));

    // Verify screencapture was called with -R flag
    let cmds = commands.lock().unwrap();
    let capture_cmd = cmds.iter().find(|c| c.contains("screencapture")).unwrap();
    assert!(
        capture_cmd.contains("-R 100,200,400,300"),
        "should use -R flag: {capture_cmd}"
    );

    // Verify text includes region coordinate info
    let text = extract_text(&r);
    assert!(text.contains("Region at"), "should mention region: {text}");
    assert!(text.contains("100"), "should include region x: {text}");
    assert!(text.contains("200"), "should include region y: {text}");

    // Verify details include region info
    let d = r.details.unwrap();
    assert_eq!(d["regionX"], 100);
    assert_eq!(d["regionY"], 200);
    assert_eq!(d["regionWidth"], 400);
    assert_eq!(d["regionHeight"], 300);
}

#[tokio::test]
async fn screenshot_region_rejects_zero_dimensions() {
    let t = tool(false);
    let r = t
        .execute(
            json!({
                "action": "screenshot",
                "region": {"x": 100, "y": 200, "width": 0, "height": 300}
            }),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("positive"));

    let r = t
        .execute(
            json!({
                "action": "screenshot",
                "region": {"x": 100, "y": 200, "width": 400, "height": -10}
            }),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("positive"));
}

#[tokio::test]
async fn screenshot_region_screencapture_failure() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("screencapture") {
            ProcessOutput {
                stdout: String::new(),
                stderr: "screen recording not permitted".into(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({
                "action": "screenshot",
                "region": {"x": 0, "y": 0, "width": 100, "height": 100}
            }),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    assert!(extract_text(&r).contains("Region screenshot failed"));
    assert!(extract_text(&r).contains("Screen Recording"));
}

// ─── Window selection scoring tests ───

#[tokio::test]
async fn screenshot_window_swift_uses_scoring() {
    // The Swift script should use scoring logic, not first-match-wins.
    // Capture the command string and verify it contains scoring keywords.
    use std::sync::{Arc as StdArc, Mutex};
    let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
    let cmds = commands.clone();
    let runner = MockRunner::with_handler(move |cmd| {
        cmds.lock().unwrap().push(cmd.to_string());
        // Swift script should fail (no real CGWindowList in test)
        ProcessOutput {
            stdout: String::new(),
            stderr: "Safari: Start Page".into(),
            exit_code: 1,
            duration_ms: 10,
            timed_out: false,
            interrupted: false,
        }
    });
    let t = tool_with_runner(runner, false);
    let _ = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await;
    let cmds = commands.lock().unwrap();
    let swift_cmd = cmds
        .iter()
        .find(|c| c.contains("swift"))
        .expect("should run swift");
    assert!(
        swift_cmd.contains("kCGWindowLayer"),
        "script should check window layer"
    );
    assert!(
        swift_cmd.contains("kCGWindowIsOnscreen"),
        "script should check on-screen state"
    );
    assert!(
        swift_cmd.contains("kCGWindowBounds"),
        "script should check window bounds"
    );
}

#[tokio::test]
async fn screenshot_window_not_found_lists_available() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: String::new(),
                stderr: "Safari: Start Page\nArc: Tab1".into(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "NonexistentApp"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(text.contains("not found"), "should say not found: {text}");
    assert!(
        text.contains("Available windows"),
        "should list available: {text}"
    );
}

#[tokio::test]
async fn screenshot_window_not_found_empty_list() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Nothing"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(text.contains("not found"), "should say not found: {text}");
}

#[tokio::test]
async fn focus_window_uses_nsrunningapplication() {
    // Verify the Swift script uses NSRunningApplication.activate, not osascript
    use std::sync::{Arc as StdArc, Mutex};
    let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
    let cmds = commands.clone();
    let runner = MockRunner::with_handler(move |cmd| {
        cmds.lock().unwrap().push(cmd.to_string());
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Safari\tApple\t12345\tactivated\ttrue".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let _ = t
        .execute(
            json!({"action": "focusWindow", "window": "Safari"}),
            &make_ctx(),
        )
        .await;
    let cmds = commands.lock().unwrap();
    let swift_cmd = cmds
        .iter()
        .find(|c| c.contains("swift"))
        .expect("should run swift");
    assert!(
        swift_cmd.contains("NSRunningApplication"),
        "should use NSRunningApplication"
    );
    assert!(swift_cmd.contains("activate"), "should call activate");
    assert!(
        swift_cmd.contains("activateIgnoringOtherApps"),
        "should use activateIgnoringOtherApps"
    );
    // Should NOT use osascript "set frontmost"
    assert!(
        !cmds
            .iter()
            .any(|c| c.contains("osascript") && c.contains("frontmost")),
        "should not use osascript set frontmost"
    );
}

#[tokio::test]
async fn focus_window_not_found_lists_available() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: String::new(),
                stderr: "Xcode: Project\nFinder: Downloads".into(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "NonexistentApp"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(text.contains("not found"), "should say not found: {text}");
    assert!(
        text.contains("Available windows"),
        "should list available: {text}"
    );
}

#[tokio::test]
async fn focus_window_activated_and_verified() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Safari\tApple\t12345\tactivated\ttrue".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    assert!(
        text.contains("verified on-screen"),
        "should say verified: {text}"
    );
    let d = r.details.unwrap();
    assert_eq!(d["verified"], true);
    assert_eq!(d["activated"], true);
}

#[tokio::test]
async fn focus_window_activated_but_unverified() {
    // App activated but no window became onScreen (e.g., other Space issue)
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Safari\tApple\t12345\tactivated\tfalse".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "should still succeed (activation worked): {}",
        extract_text(&r)
    );
    let text = extract_text(&r);
    assert!(
        text.contains("not yet verified"),
        "should warn about unverified: {text}"
    );
    let d = r.details.unwrap();
    assert_eq!(d["verified"], false);
}

#[tokio::test]
async fn focus_window_activation_failed() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Safari\tApple\t12345\tfailed\tfalse".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(
        text.contains("activation failed"),
        "should say failed: {text}"
    );
}

#[tokio::test]
async fn focus_window_no_process() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Safari\tApple\t99999\tno_process\tfalse".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(
        text.contains("activation failed"),
        "should say failed: {text}"
    );
}

// ─── clickElement tests ───

#[tokio::test]
async fn click_element_pressed() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "found\tpressed\tAXButton\tSubmit\t0\t0\t0\t0".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "clickElement", "text": "Submit", "confirmed": true}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let text = extract_text(&r);
    assert!(text.contains("Submit"), "should mention element: {text}");
    assert!(text.contains("pressed"), "should say pressed: {text}");
    let d = r.details.unwrap();
    assert_eq!(d["action"], "clickElement");
    assert_eq!(d["method"], "pressed");
}

#[tokio::test]
async fn click_element_clicked_fallback() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "found\tclicked\tAXLink\tLearn more\t200\t300\t100\t20".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "clickElement", "text": "Learn more", "confirmed": true}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let d = r.details.unwrap();
    assert_eq!(d["method"], "clicked");
}

#[tokio::test]
async fn click_element_not_found() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: String::new(),
                stderr: "AXButton: OK\nAXLink: Cancel".into(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "clickElement", "text": "Nonexistent", "confirmed": true}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(text.contains("not found"), "should say not found: {text}");
    assert!(
        text.contains("Available elements"),
        "should list available: {text}"
    );
}

#[tokio::test]
async fn click_element_requires_confirmation() {
    let t = tool(true);
    let r = t
        .execute(
            json!({"action": "clickElement", "text": "Submit"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(
        text.contains("requires confirmation"),
        "should require confirmation: {text}"
    );
}

#[tokio::test]
async fn click_element_missing_text() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "clickElement", "confirmed": true}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn click_element_is_mutating() {
    assert!(ComputerUseTool::is_mutating("clickElement"));
}

// ─── Window visibility diagnosis tests ───

/// Helper: create a MockRunner for window screenshot tests.
/// `swift_stdout`: what the Swift script returns on stdout (e.g., "42\ttrue\t1920\t1080")
/// `swift_exit`: exit code of Swift script (0=found, 1=not found)
/// `capture_exit`: exit code of screencapture (0=success, 1=failure)
/// `capture_stderr`: stderr from screencapture
fn window_screenshot_runner(
    swift_stdout: &str,
    swift_exit: i32,
    capture_exit: i32,
    capture_stderr: &str,
) -> MockRunner {
    let swift_out = swift_stdout.to_string();
    let cap_stderr = capture_stderr.to_string();
    MockRunner::with_handler(move |cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: swift_out.clone(),
                stderr: String::new(),
                exit_code: swift_exit,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else if cmd.contains("screencapture") {
            if capture_exit == 0 {
                // Create a fake PNG with valid IHDR header
                let path = cmd.rsplit(' ').next().unwrap_or("/tmp/test.png");
                let mut data = Vec::with_capacity(5000);
                data.extend_from_slice(b"\x89PNG\r\n\x1a\n"); // signature
                data.extend_from_slice(&13u32.to_be_bytes()); // IHDR length
                data.extend_from_slice(b"IHDR");
                data.extend_from_slice(&1280u32.to_be_bytes()); // width
                data.extend_from_slice(&960u32.to_be_bytes()); // height
                data.resize(5000, 0);
                std::fs::write(path, &data).ok();
            }
            ProcessOutput {
                stdout: String::new(),
                stderr: cap_stderr.clone(),
                exit_code: capture_exit,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else if cmd.contains("sips") {
            // sips fails in test (no real image) — fallback to PNG
            ProcessOutput {
                stdout: String::new(),
                stderr: "not a valid image".into(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    })
}

#[tokio::test]
async fn screenshot_offscreen_window_capture_succeeds() {
    // kCGWindowIsOnscreen=false but screencapture succeeds (the common case:
    // window on another Space, or background launchd reports false).
    // Must NOT block — should attempt capture and succeed.
    let runner = window_screenshot_runner("42\tfalse\t1187\t1100", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "should succeed despite onScreen=false: {}",
        extract_text(&r)
    );
    let d = r.details.unwrap();
    assert_eq!(d["action"], "screenshot");
    assert_eq!(d["window"], "Safari");
}

#[tokio::test]
async fn screenshot_offscreen_zero_size_capture_succeeds() {
    // Even with zero-size metadata, attempt capture (metadata can be wrong)
    let runner = window_screenshot_runner("42\tfalse\t0\t0", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "should attempt capture regardless: {}",
        extract_text(&r)
    );
}

#[tokio::test]
async fn screenshot_capture_failure_includes_diagnostics() {
    // screencapture fails → error should include stderr and suggest permission
    let runner = window_screenshot_runner(
        "42\ttrue\t1187\t1100",
        0,
        1,
        "could not create image from window",
    );
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(
        text.contains("could not create image"),
        "should include stderr: {text}"
    );
}

#[tokio::test]
async fn screenshot_capture_failure_offscreen_suggests_focus() {
    // screencapture fails AND window was off-screen → suggest focusWindow
    let runner = window_screenshot_runner(
        "42\tfalse\t1187\t1100",
        0,
        1,
        "could not create image from window",
    );
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let text = extract_text(&r);
    assert!(
        text.contains("focusWindow") || text.contains("off-screen"),
        "should mention off-screen context: {text}"
    );
}

#[tokio::test]
async fn screenshot_onscreen_window_succeeds() {
    // Window on-screen, capture succeeds → should return image
    let runner = window_screenshot_runner("42\ttrue\t1187\t1100", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    let d = r.details.unwrap();
    assert_eq!(d["action"], "screenshot");
    assert_eq!(d["window"], "Safari");
}

#[tokio::test]
async fn screenshot_window_metadata_only_id() {
    // Swift returns only window ID (no metadata) → should proceed to capture
    let runner = window_screenshot_runner("42", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "should succeed with partial metadata: {}",
        extract_text(&r)
    );
}

#[tokio::test]
async fn screenshot_details_include_screen_resolution() {
    // Full-screen screenshot should include screen dimensions in details
    let runner = screenshot_runner(5000, None);
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(json!({"action": "screenshot"}), &make_ctx())
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    // On macOS test environment, screen_bounds() should return real values
    // On non-macOS or test, these may be absent — that's OK
    #[cfg(target_os = "macos")]
    {
        let d = r.details.unwrap();
        assert!(d.get("screenWidth").is_some(), "should have screenWidth");
        assert!(d.get("screenHeight").is_some(), "should have screenHeight");
    }
}

#[tokio::test]
async fn screenshot_window_details_include_screen_resolution() {
    // Window screenshot should also include screen dimensions
    let runner = window_screenshot_runner("42\ttrue\t1187\t1100", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(r.is_error.is_none(), "should succeed: {}", extract_text(&r));
    #[cfg(target_os = "macos")]
    {
        let d = r.details.unwrap();
        assert!(d.get("screenWidth").is_some(), "should have screenWidth");
        assert!(d.get("screenHeight").is_some(), "should have screenHeight");
    }
}

#[tokio::test]
async fn screenshot_window_metadata_partial() {
    // Swift returns "42\ttrue" (missing width/height) → should proceed to capture
    let runner = window_screenshot_runner("42\ttrue", 0, 0, "");
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "screenshot", "window": "Safari"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    assert!(
        r.is_error.is_none(),
        "should succeed with partial metadata: {}",
        extract_text(&r)
    );
}

#[tokio::test]
async fn screenshot_window_special_chars_escaped() {
    // Verify window names with quotes/backslashes are properly escaped
    use std::sync::{Arc as StdArc, Mutex};
    let commands: StdArc<Mutex<Vec<String>>> = StdArc::new(Mutex::new(Vec::new()));
    let cmds = commands.clone();
    let runner = MockRunner::with_handler(move |cmd| {
        cmds.lock().unwrap().push(cmd.to_string());
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 1,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let _ = t
        .execute(
            json!({"action": "screenshot", "window": "App \"with\" quotes"}),
            &make_ctx(),
        )
        .await;
    let cmds = commands.lock().unwrap();
    let swift_cmd = cmds
        .iter()
        .find(|c| c.contains("swift"))
        .expect("should run swift");
    // The escaped double quotes should appear as \" in the Swift string
    assert!(
        swift_cmd.contains(r#"\""#),
        "quotes should be escaped in swift: {swift_cmd}"
    );
}

// ─── Confirmation describe_action tests ───

#[test]
fn describe_type_action_truncated() {
    let t = tool(true);
    let desc = t.describe_action(
        "type",
        &json!({"text": "This is a very long string that should be truncated in the description"}),
    );
    assert!(desc.contains("..."));
    assert!(desc.len() < 60);
}

#[test]
fn describe_keypress_action() {
    let t = tool(true);
    let desc = t.describe_action("keypress", &json!({"keys": ["cmd", "c"]}));
    assert_eq!(desc, "Press keys: cmd+c");
}

// ─── is_mutating tests ───

#[test]
fn mutating_actions_identified() {
    assert!(ComputerUseTool::is_mutating("clickElement"));
    assert!(ComputerUseTool::is_mutating("type"));
    assert!(ComputerUseTool::is_mutating("keypress"));
    assert!(ComputerUseTool::is_mutating("scroll"));
}

#[test]
fn readonly_actions_not_mutating() {
    assert!(!ComputerUseTool::is_mutating("screenshot"));
    assert!(!ComputerUseTool::is_mutating("getWindows"));
    assert!(!ComputerUseTool::is_mutating("focusWindow"));
    assert!(!ComputerUseTool::is_mutating("listElements"));
}

// ─── Details/audit logging tests ───

#[tokio::test]
async fn scroll_details_include_direction() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "scroll", "direction": "up", "amount": 50}),
            &make_ctx(),
        )
        .await
        .unwrap();
    let d = r.details.unwrap();
    assert_eq!(d["action"], "scroll");
    assert_eq!(d["direction"], "up");
    assert_eq!(d["amount"], 50);
}

#[tokio::test]
async fn type_details_include_length() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "type", "text": "test"}), &make_ctx())
        .await
        .unwrap();
    let d = r.details.unwrap();
    assert_eq!(d["action"], "type");
    assert_eq!(d["length"], 4);
}

#[tokio::test]
async fn keypress_details_include_keys() {
    let t = tool(false);
    let r = t
        .execute(
            json!({"action": "keypress", "keys": ["cmd", "v"]}),
            &make_ctx(),
        )
        .await
        .unwrap();
    let d = r.details.unwrap();
    assert_eq!(d["action"], "keypress");
    let keys = d["keys"].as_array().unwrap();
    assert_eq!(keys.len(), 2);
}

#[tokio::test]
async fn get_windows_details() {
    let t = tool(false);
    let r = t
        .execute(json!({"action": "getWindows"}), &make_ctx())
        .await
        .unwrap();
    let d = r.details.unwrap();
    assert_eq!(d["action"], "getWindows");
}

#[tokio::test]
async fn focus_window_details() {
    let runner = MockRunner::with_handler(|cmd| {
        if cmd.contains("swift") {
            ProcessOutput {
                stdout: "Xcode\tProject\t5678\tactivated\ttrue".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        } else {
            ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 10,
                timed_out: false,
                interrupted: false,
            }
        }
    });
    let t = tool_with_runner(runner, false);
    let r = t
        .execute(
            json!({"action": "focusWindow", "window": "Xcode"}),
            &make_ctx(),
        )
        .await
        .unwrap();
    let d = r.details.unwrap();
    assert_eq!(d["action"], "focusWindow");
    assert_eq!(d["window"], "Xcode");
    assert_eq!(d["app"], "Xcode");
    assert_eq!(d["pid"], 5678);
    assert_eq!(d["activated"], true);
    assert_eq!(d["verified"], true);
}

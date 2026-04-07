use super::*;

impl ComputerUseTool {
    /// Get screen resolution (width, height) via enigo (CGEvent-based, no subprocess).
    pub(super) async fn screen_bounds(&self) -> Option<(f64, f64)> {
        #[cfg(target_os = "macos")]
        {
            match super::super::input::screen_size().await {
                Ok((w, h)) => Some((f64::from(w), f64::from(h))),
                Err(_) => None,
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            None
        }
    }

    pub(super) async fn take_screenshot(
        &self,
        params: &Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        use base64::Engine;

        // Screenshot throttle
        let now = Self::now_ms();
        let last = self.last_screenshot_ms.load(Ordering::Relaxed);
        if last > 0 && now.saturating_sub(last) < self.screenshot_throttle_ms {
            let wait = self.screenshot_throttle_ms - (now - last);
            return Ok(error_result(format!(
                "Screenshot throttled. Please wait {wait}ms before taking another screenshot."
            )));
        }

        let tmp_path = format!("/tmp/tron-screenshot-{}.png", uuid::Uuid::now_v7());
        let window = get_optional_string(params, "window");
        let region = params.get("region").and_then(Value::as_object);

        // Window logical dimensions and position (set during window lookup below)
        let mut win_w: f64 = 0.0;
        let mut win_h: f64 = 0.0;
        let mut win_x: f64 = 0.0;
        let mut win_y: f64 = 0.0;

        // Region dimensions (set during region capture below)
        let mut region_x: f64 = 0.0;
        let mut region_y: f64 = 0.0;
        let mut region_w: f64 = 0.0;
        let mut region_h: f64 = 0.0;

        if let Some(ref w) = window {
            // Window-specific capture: use scored CGWindowList lookup via Swift to find
            // the best matching window ID, then screencapture -l <id>.
            // Scoring prefers on-screen, layer-0, largest-area windows to avoid
            // matching non-capturable system/accessory windows.
            let swift_script = Self::build_screenshot_window_swift(w);
            let wid_command = format!("swift -e '{}'", swift_script.replace('\'', "'\\''"));
            let wid_output = self.run_shell(&wid_command, ctx).await?;

            if wid_output.exit_code != 0 {
                let available = wid_output.stderr.trim();
                let window_list = if available.is_empty() {
                    String::new()
                } else {
                    format!(" Available windows:\n{available}")
                };
                return Ok(error_result(format!(
                    "Window '{w}' not found.{window_list}",
                )));
            }

            // Parse: "windowId\tonScreen\twidth\theight\tx\ty"
            let parts: Vec<&str> = wid_output.stdout.trim().splitn(6, '\t').collect();
            let window_id = parts.first().unwrap_or(&"").to_string();
            let on_screen = parts.get(1).map(|s| *s == "true").unwrap_or(true);
            win_w = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0.0);
            win_h = parts.get(3).and_then(|s| s.parse().ok()).unwrap_or(0.0);
            win_x = parts.get(4).and_then(|s| s.parse().ok()).unwrap_or(0.0);
            win_y = parts.get(5).and_then(|s| s.parse().ok()).unwrap_or(0.0);

            tracing::debug!(
                window = %w, id = %window_id, on_screen, width = win_w, height = win_h,
                "Window lookup result for screenshot"
            );

            // Always attempt capture — kCGWindowIsOnscreen is unreliable (reports false
            // for windows on other Spaces or when running from a background launchd process,
            // but screencapture -l can still capture them successfully).
            let capture_command = format!("screencapture -x -t png -l {window_id} {tmp_path}");
            let output = self.run_shell(&capture_command, ctx).await?;
            if output.exit_code != 0 {
                tracing::debug!(
                    window = %w, id = %window_id, on_screen, stderr = %output.stderr.trim(),
                    "screencapture failed for window"
                );
                let hint = if on_screen {
                    "Grant Screen Recording permission in System Settings > Privacy & Security."
                } else {
                    "The window may be minimized or off-screen. Try focusWindow first, or grant Screen Recording permission."
                };
                return Ok(error_result(format!(
                    "Window screenshot failed: {}. {hint}",
                    output.stderr.trim()
                )));
            }
        } else if let Some(r) = region {
            // Region capture: use screencapture -R x,y,width,height
            region_x = r.get("x").and_then(Value::as_f64).unwrap_or(0.0);
            region_y = r.get("y").and_then(Value::as_f64).unwrap_or(0.0);
            region_w = r.get("width").and_then(Value::as_f64).unwrap_or(0.0);
            region_h = r.get("height").and_then(Value::as_f64).unwrap_or(0.0);

            if region_w <= 0.0 || region_h <= 0.0 {
                return Ok(error_result(
                    "Region width and height must be positive numbers.".to_string(),
                ));
            }

            // On Retina displays, screencapture -R uses screen points (logical coordinates),
            // which is what we want since the agent works in logical coordinates.
            #[allow(clippy::cast_possible_truncation)]
            let command = format!(
                "screencapture -x -t png -R {},{},{},{} {tmp_path}",
                region_x as i32, region_y as i32, region_w as i32, region_h as i32
            );
            let output = self.run_shell(&command, ctx).await?;
            if output.exit_code != 0 {
                return Ok(error_result(format!(
                    "Region screenshot failed: {}. Grant Screen Recording permission in System Settings > Privacy & Security.",
                    output.stderr
                )));
            }
        } else {
            // Full screen capture
            let command = format!("screencapture -x -t png {tmp_path}");
            let output = self.run_shell(&command, ctx).await?;
            if output.exit_code != 0 {
                return Ok(error_result(format!(
                    "Screenshot failed: {}. Grant Screen Recording permission in System Settings > Privacy & Security.",
                    output.stderr
                )));
            }
        }

        // Read the raw PNG screenshot
        let _raw_data = match tokio::fs::read(&tmp_path).await {
            Ok(data) => data,
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp_path).await;
                return Ok(error_result(format!("Failed to read screenshot: {e}")));
            }
        };

        // Step 1: Resize PNG to exact logical dimensions so that
        // 1 image pixel = 1 screen point. This eliminates all coordinate math —
        // the agent clicks exactly where it sees in the image.
        //
        // For window screenshots, resize to the window's logical dimensions.
        // For full screen, resize to the screen's logical dimensions.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let resize_target = if window.is_some() {
            // Use window logical dimensions (from CGWindowList metadata)
            (win_w as u32, win_h as u32)
        } else if region.is_some() {
            // Use region logical dimensions
            (region_w as u32, region_h as u32)
        } else {
            // Use screen logical dimensions
            self.screen_bounds().await
                .map(|(w, h)| (w as u32, h as u32))
                .unwrap_or((1280, 800))
        };

        let resize_cmd = format!(
            "sips --resampleWidth {} --resampleHeight {} '{tmp_path}'",
            resize_target.0, resize_target.1
        );
        let _ = self.run_shell(&resize_cmd, ctx).await;

        // Read the resized PNG
        let resized_png = match tokio::fs::read(&tmp_path).await {
            Ok(data) => data,
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp_path).await;
                return Ok(error_result(format!("Failed to read resized screenshot: {e}")));
            }
        };
        let original_size = resized_png.len();

        // Parse image dimensions from PNG header (bytes 16-23 of IHDR chunk)
        // Step 2: Try JPEG compression on the resized PNG.
        let jpg_path = format!("{}.jpg", &tmp_path[..tmp_path.len() - 4]);
        let sips_cmd = format!(
            "sips --setProperty format jpeg --setProperty formatOptions 70 '{tmp_path}' --out '{jpg_path}'",
        );
        let sips_result = self.run_shell(&sips_cmd, ctx).await;
        let _ = tokio::fs::remove_file(&tmp_path).await;

        let (image_data, mime_type) = match sips_result {
            Ok(output) if output.exit_code == 0 => {
                match tokio::fs::read(&jpg_path).await {
                    Ok(data) if !data.is_empty() && data.len() < resized_png.len() => {
                        tracing::debug!(
                            jpeg_bytes = data.len(), png_bytes = original_size,
                            "Using JPEG (smaller than PNG)"
                        );
                        let _ = tokio::fs::remove_file(&jpg_path).await;
                        (data, "image/jpeg")
                    }
                    Ok(data) => {
                        tracing::debug!(
                            jpeg_bytes = data.len(), png_bytes = original_size,
                            "Skipping JPEG (not smaller than PNG), using PNG"
                        );
                        let _ = tokio::fs::remove_file(&jpg_path).await;
                        (resized_png, "image/png")
                    }
                    _ => {
                        tracing::debug!("JPEG read failed, falling back to PNG");
                        let _ = tokio::fs::remove_file(&jpg_path).await;
                        (resized_png, "image/png")
                    }
                }
            }
            _ => {
                tracing::debug!("sips compression failed, using original PNG");
                let _ = tokio::fs::remove_file(&jpg_path).await;
                (resized_png, "image/png")
            }
        };

        // Save to persistent screenshots directory so Display tool can reference the file.
        // In tests, ctx.working_directory is /tmp — we save there instead of polluting ~/.tron/.
        let ext = if mime_type == "image/jpeg" { "jpg" } else { "png" };
        let now = chrono::Local::now();
        let date = now.format("%Y-%m-%d");
        let time = now.format("%H%M%S");
        let rand_suffix: u16 = rand::random();
        let screenshot_filename = format!("{date}-{time}-screenshot-{rand_suffix:04x}.{ext}");
        let screenshots_dir = if cfg!(test) {
            std::path::PathBuf::from(&ctx.working_directory).join("screenshots")
        } else {
            crate::core::paths::screenshots_dir()
        };
        let _ = tokio::fs::create_dir_all(&screenshots_dir).await;
        let screenshot_path = screenshots_dir.join(&screenshot_filename);

        let saved_path = match tokio::fs::write(&screenshot_path, &image_data).await {
            Ok(()) => {
                tracing::debug!(path = %screenshot_path.display(), "Screenshot saved");
                Some(screenshot_path.to_string_lossy().to_string())
            }
            Err(e) => {
                tracing::warn!(error = %e, "Failed to persist screenshot — continuing without file");
                None
            }
        };

        // Update throttle timestamp
        self.last_screenshot_ms.store(Self::now_ms(), Ordering::Relaxed);

        let b64 = base64::engine::general_purpose::STANDARD.encode(&image_data);

        // Include screen resolution and image dimensions for coordinate mapping
        let screen = self.screen_bounds().await;

        // Size guard: if a window capture is suspiciously small, it's likely
        // blank/minimized/off-screen. Warn the agent so it can focus the window first.
        let size_warning = if window.is_some() && image_data.len() < 10_000 {
            "\nWARNING: Screenshot appears blank or very small — the window may be minimized or on another desktop. Try using focusWindow first to bring it to the current screen, then retry the screenshot."
        } else {
            ""
        };

        let mut details = json!({
            "action": "screenshot",
            "window": window,
            "sizeBytes": image_data.len(),
            "mimeType": mime_type,
        });
        if let Some((w, h)) = screen {
            details["screenWidth"] = json!(w);
            details["screenHeight"] = json!(h);
        }
        if window.is_some() {
            details["windowX"] = json!(win_x as i32);
            details["windowY"] = json!(win_y as i32);
        }
        if region.is_some() {
            details["regionX"] = json!(region_x as i32);
            details["regionY"] = json!(region_y as i32);
            details["regionWidth"] = json!(region_w as i32);
            details["regionHeight"] = json!(region_h as i32);
        }
        details["screenshotPath"] = json!(saved_path);

        let format_label = if mime_type == "image/jpeg" { "JPEG" } else { "PNG" };
        let mut text = format!(
            "Screenshot captured ({} bytes {format_label})",
            image_data.len()
        );

        // 1:1 coordinate guide — image pixels map directly to screen points
        if window.is_some() {
            #[allow(clippy::cast_possible_truncation)]
            {
                text.push_str(&format!(
                    "\nWindow at ({}, {}). Pixel (x,y) in this image = screen point ({} + x, {} + y).",
                    win_x as i32, win_y as i32, win_x as i32, win_y as i32
                ));
            }
        } else if region.is_some() {
            #[allow(clippy::cast_possible_truncation)]
            {
                text.push_str(&format!(
                    "\nRegion at ({}, {}), size {}x{}. Pixel (x,y) in this image = screen point ({} + x, {} + y).",
                    region_x as i32, region_y as i32, region_w as i32, region_h as i32,
                    region_x as i32, region_y as i32
                ));
            }
        } else if let Some((sw, sh)) = screen {
            text.push_str(&format!(
                "\nScreen is {sw}x{sh}. Image is 1:1 with screen — pixel (x,y) in this image = screen point (x,y)."
            ));
        }

        if !size_warning.is_empty() {
            text.push_str(size_warning);
        }

        if let Some(ref path) = saved_path {
            text.push_str(&format!("\nScreenshot saved to: {path}"));
            text.push_str(
                "\nUse Display(type: \"image\", path: \"<this path>\") to show it to the user.",
            );
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                crate::core::content::ToolResultContent::Image {
                    data: b64,
                    mime_type: mime_type.into(),
                },
                crate::core::content::ToolResultContent::text(text),
            ]),
            details: Some(details),
            is_error: None,
            stop_turn: None,
        })
    }
}

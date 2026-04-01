//! Output truncation utilities.
//!
//! Provides token-based truncation (with line preservation) and character-based
//! head+tail truncation (with blob reference markers). Used by the Bash tool,
//! ProcessManager, Wait tool, and JobManager.

/// Default characters per token for estimation.
pub const DEFAULT_CHARS_PER_TOKEN: usize = 4;

/// Output size above which blob storage is used and inline content is head+tail.
pub const INLINE_OUTPUT_LIMIT: usize = 30_000;
/// Characters to keep from the start when truncating to head+tail.
pub const HEAD_CHARS: usize = 20_000;
/// Characters to keep from the end when truncating to head+tail.
pub const TAIL_CHARS: usize = 8_000;
/// Maximum output shown per job in Wait tool results.
pub const WAIT_OUTPUT_LIMIT: usize = 4_000;

/// Estimate token count from character count.
pub fn estimate_tokens(chars: usize) -> usize {
    chars.div_ceil(DEFAULT_CHARS_PER_TOKEN)
}

/// Convert token count to character budget.
pub fn tokens_to_chars(tokens: usize) -> usize {
    tokens * DEFAULT_CHARS_PER_TOKEN
}

/// Options controlling truncation behavior.
#[derive(Clone, Debug, Default)]
pub struct TruncateOptions {
    /// Number of lines to preserve at the start.
    pub preserve_start_lines: usize,
    /// Number of lines to preserve at the end.
    pub preserve_end_lines: usize,
    /// Custom truncation indicator message.
    pub truncation_message: Option<String>,
}

/// Truncate output to fit within a token budget.
///
/// If the output fits within `max_tokens`, returns it unchanged.
/// Otherwise, preserves the first `preserve_start_lines` and last
/// `preserve_end_lines`, inserting a truncation indicator in the middle.
pub fn truncate_output(output: &str, max_tokens: usize, options: &TruncateOptions) -> String {
    let original_tokens = estimate_tokens(output.len());

    if original_tokens <= max_tokens {
        return output.to_owned();
    }

    let max_chars = tokens_to_chars(max_tokens);
    let lines: Vec<&str> = output.lines().collect();

    let message = options
        .truncation_message
        .clone()
        .unwrap_or_else(|| {
            format!(
                "\n... [output truncated: {original_tokens} tokens exceeded {max_tokens} token budget] ...\n"
            )
        });

    let message_chars = message.len();

    // If we have preserve directives and enough lines
    if (options.preserve_start_lines > 0 || options.preserve_end_lines > 0) && lines.len() > 1 {
        let start_count = options.preserve_start_lines.min(lines.len());
        let end_count = options
            .preserve_end_lines
            .min(lines.len().saturating_sub(start_count));

        let start_part = lines[..start_count].join("\n");
        let end_part = if end_count > 0 {
            lines[lines.len() - end_count..].join("\n")
        } else {
            String::new()
        };

        return if end_part.is_empty() {
            format!("{start_part}{message}")
        } else {
            format!("{start_part}{message}{end_part}")
        };
    }

    // Simple character-based truncation (UTF-8–safe)
    let available = max_chars.saturating_sub(message_chars);
    if available > 0 && available < output.len() {
        let safe_slice = crate::core::text::truncate_str(output, available);
        // Try to break at a line boundary
        let break_at = safe_slice.rfind('\n').map_or(safe_slice.len(), |pos| pos);
        format!("{}{message}", &output[..break_at])
    } else {
        message
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// UTF-8–safe character boundary helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Find a UTF-8–safe char boundary at or before `target` byte index.
pub fn safe_char_boundary(s: &str, target: usize) -> usize {
    if target >= s.len() {
        return s.len();
    }
    let mut boundary = 0;
    for (i, _) in s.char_indices() {
        if i > target {
            break;
        }
        boundary = i;
    }
    boundary
}

/// Find a UTF-8–safe char boundary at or after `target` byte index.
pub fn safe_char_boundary_ceil(s: &str, target: usize) -> usize {
    if target >= s.len() {
        return s.len();
    }
    for (i, _) in s.char_indices() {
        if i >= target {
            return i;
        }
    }
    s.len()
}

// ─────────────────────────────────────────────────────────────────────────────
// Head+tail truncation with blob reference
// ─────────────────────────────────────────────────────────────────────────────

/// Truncate output to head + marker + tail.
///
/// If `output.len() <= limit`, returns it unchanged.
/// Otherwise, keeps `head` chars from the start and `tail` chars from the end,
/// with a marker in between indicating how much was omitted and optionally
/// referencing the blob where full content is stored.
pub fn truncate_head_tail(
    output: &str,
    limit: usize,
    head: usize,
    tail: usize,
    blob_id: Option<&str>,
) -> String {
    if output.len() <= limit {
        return output.to_owned();
    }

    let head_end = safe_char_boundary(output, head);
    let tail_start = safe_char_boundary_ceil(output, output.len().saturating_sub(tail));
    let omitted = tail_start.saturating_sub(head_end);

    let marker = if let Some(id) = blob_id {
        format!("\n\n... [{omitted} chars omitted — stored as {id}] ...\n\n")
    } else {
        format!("\n\n... [{omitted} chars omitted] ...\n\n")
    };

    let mut result = String::with_capacity(head_end + marker.len() + (output.len() - tail_start));
    result.push_str(&output[..head_end]);
    result.push_str(&marker);
    result.push_str(&output[tail_start..]);
    result
}

/// Truncate to the last `limit` characters, with a marker showing how much was cut.
///
/// If `output.len() <= limit`, returns it unchanged.
pub fn truncate_tail(output: &str, limit: usize) -> String {
    if output.len() <= limit {
        return output.to_owned();
    }

    let start = safe_char_boundary_ceil(output, output.len().saturating_sub(limit));
    let omitted = start;

    format!("[... {omitted} chars truncated]\n{}", &output[start..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimate_tokens_100_chars() {
        assert_eq!(estimate_tokens(100), 25);
    }

    #[test]
    fn estimate_tokens_0_chars() {
        assert_eq!(estimate_tokens(0), 0);
    }

    #[test]
    fn tokens_to_chars_25_tokens() {
        assert_eq!(tokens_to_chars(25), 100);
    }

    #[test]
    fn within_budget_no_truncation() {
        let output = "hello world";
        let result = truncate_output(output, 100, &TruncateOptions::default());
        assert_eq!(result, "hello world");
    }

    #[test]
    fn over_budget_truncated_with_message() {
        let output = "a".repeat(1000);
        let result = truncate_output(&output, 10, &TruncateOptions::default());
        assert!(result.contains("truncated"));
        assert!(result.len() < output.len());
    }

    #[test]
    fn empty_string_no_truncation() {
        let result = truncate_output("", 100, &TruncateOptions::default());
        assert_eq!(result, "");
    }

    #[test]
    fn single_line_at_budget() {
        // 20 chars = 5 tokens
        let output = "a".repeat(20);
        let result = truncate_output(&output, 5, &TruncateOptions::default());
        assert_eq!(result, output);
    }

    #[test]
    fn preserve_start_lines() {
        let lines: Vec<String> = (1..=100).map(|i| format!("line {i}")).collect();
        let output = lines.join("\n");
        let opts = TruncateOptions {
            preserve_start_lines: 5,
            ..Default::default()
        };
        let result = truncate_output(&output, 10, &opts);
        assert!(result.starts_with("line 1\n"));
        assert!(result.contains("line 5"));
        assert!(result.contains("truncated"));
    }

    #[test]
    fn preserve_end_lines() {
        let lines: Vec<String> = (1..=100).map(|i| format!("line {i}")).collect();
        let output = lines.join("\n");
        let opts = TruncateOptions {
            preserve_end_lines: 3,
            ..Default::default()
        };
        let result = truncate_output(&output, 10, &opts);
        assert!(result.contains("line 100"));
        assert!(result.contains("truncated"));
    }

    #[test]
    fn preserve_start_and_end_lines() {
        let lines: Vec<String> = (1..=100).map(|i| format!("line {i}")).collect();
        let output = lines.join("\n");
        let opts = TruncateOptions {
            preserve_start_lines: 3,
            preserve_end_lines: 2,
            ..Default::default()
        };
        let result = truncate_output(&output, 10, &opts);
        assert!(result.starts_with("line 1\n"));
        assert!(result.contains("line 100"));
        assert!(result.contains("truncated"));
    }

    #[test]
    fn message_alone_exceeds_budget() {
        let output = "a".repeat(1000);
        // Budget so small even the message exceeds it
        let result = truncate_output(&output, 1, &TruncateOptions::default());
        assert!(result.contains("truncated"));
    }

    #[test]
    fn custom_truncation_message() {
        let output = "a".repeat(1000);
        let opts = TruncateOptions {
            truncation_message: Some("[SNIP]".into()),
            ..Default::default()
        };
        let result = truncate_output(&output, 10, &opts);
        assert!(result.contains("[SNIP]"));
    }

    #[test]
    fn multiline_mixed_lengths() {
        let mut output = String::new();
        for i in 0..50 {
            let line = "x".repeat(i * 10 + 1);
            output.push_str(&line);
            output.push('\n');
        }
        let result = truncate_output(&output, 50, &TruncateOptions::default());
        assert!(result.len() < output.len());
        assert!(result.contains("truncated"));
    }

    #[test]
    fn very_large_input() {
        let output = "a".repeat(100_000);
        let result = truncate_output(&output, 100, &TruncateOptions::default());
        assert!(result.len() < output.len());
    }

    // ── safe_char_boundary ──

    #[test]
    fn safe_boundary_ascii() {
        let s = "hello world";
        assert_eq!(safe_char_boundary(s, 5), 5);
    }

    #[test]
    fn safe_boundary_at_end() {
        let s = "hello";
        assert_eq!(safe_char_boundary(s, 100), 5);
    }

    #[test]
    fn safe_boundary_multibyte() {
        let s = "aé"; // 'a' = 1 byte, 'é' = 2 bytes, total 3 bytes
        // target=1 is mid-char for 'é' — should return 1 (start of 'é')
        assert_eq!(safe_char_boundary(s, 1), 1);
        // target=2 is mid-char for 'é' — should return 1 (start of 'é')
        assert_eq!(safe_char_boundary(s, 2), 1);
    }

    #[test]
    fn safe_boundary_ceil_ascii() {
        let s = "hello world";
        assert_eq!(safe_char_boundary_ceil(s, 5), 5);
    }

    #[test]
    fn safe_boundary_ceil_multibyte() {
        let s = "aé"; // 'a' at 0, 'é' at 1-2
        // target=2 is inside 'é' — ceil should return 3 (after 'é')
        assert_eq!(safe_char_boundary_ceil(s, 2), 3);
    }

    #[test]
    fn safe_boundary_ceil_at_end() {
        let s = "hello";
        assert_eq!(safe_char_boundary_ceil(s, 100), 5);
    }

    // ── truncate_head_tail ──

    #[test]
    fn head_tail_under_limit() {
        let s = "short";
        assert_eq!(truncate_head_tail(s, 30_000, 20_000, 8_000, None), "short");
    }

    #[test]
    fn head_tail_at_limit() {
        let s = "a".repeat(30_000);
        let result = truncate_head_tail(&s, 30_000, 20_000, 8_000, None);
        assert_eq!(result, s);
    }

    #[test]
    fn head_tail_over_limit() {
        let s = "a".repeat(50_000);
        let result = truncate_head_tail(&s, 30_000, 20_000, 8_000, None);
        assert!(result.len() < 50_000);
        assert!(result.starts_with(&"a".repeat(100))); // has head
        assert!(result.ends_with(&"a".repeat(100))); // has tail
        assert!(result.contains("chars omitted"));
        assert!(!result.contains("stored as"));
    }

    #[test]
    fn head_tail_with_blob_id() {
        let s = "a".repeat(50_000);
        let result = truncate_head_tail(&s, 30_000, 20_000, 8_000, Some("blob_abc123"));
        assert!(result.contains("stored as blob_abc123"));
    }

    #[test]
    fn head_tail_without_blob_id() {
        let s = "a".repeat(50_000);
        let result = truncate_head_tail(&s, 30_000, 20_000, 8_000, None);
        assert!(result.contains("chars omitted"));
        assert!(!result.contains("stored as"));
    }

    #[test]
    fn head_tail_empty() {
        assert_eq!(truncate_head_tail("", 30_000, 20_000, 8_000, None), "");
    }

    // ── truncate_tail ──

    #[test]
    fn tail_under_limit() {
        let s = "short";
        assert_eq!(truncate_tail(s, 4_000), "short");
    }

    #[test]
    fn tail_over_limit() {
        let s = "a".repeat(10_000);
        let result = truncate_tail(&s, 4_000);
        assert!(result.contains("chars truncated"));
        assert!(result.ends_with(&"a".repeat(100)));
        assert!(result.len() < 10_000);
    }

    #[test]
    fn tail_empty() {
        assert_eq!(truncate_tail("", 4_000), "");
    }
}

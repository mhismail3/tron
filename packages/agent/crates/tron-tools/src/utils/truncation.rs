//! Token-based output truncation with line preservation.
//!
//! Estimates token counts from character length (4 chars ≈ 1 token) and truncates
//! output while preserving configurable start/end lines.

/// Default characters per token for estimation.
pub const DEFAULT_CHARS_PER_TOKEN: usize = 4;

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
        let safe_slice = tron_core::text::truncate_str(output, available);
        // Try to break at a line boundary
        let break_at = safe_slice.rfind('\n').map_or(safe_slice.len(), |pos| pos);
        format!("{}{message}", &output[..break_at])
    } else {
        message
    }
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
}

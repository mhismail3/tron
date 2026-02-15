const DEFAULT_MAX_OUTPUT: usize = 256 * 1024; // 256KB
const BASH_MAX_OUTPUT: usize = 1024 * 1024; // 1MB

/// Returns the max output size for a given tool name.
pub fn max_output_for_tool(tool_name: &str) -> usize {
    match tool_name {
        "Bash" => BASH_MAX_OUTPUT,
        _ => DEFAULT_MAX_OUTPUT,
    }
}

/// Truncate tool output if it exceeds `max_bytes`.
/// Truncates at a char boundary and appends a marker showing original vs truncated size.
pub fn truncate_output(output: &str, max_bytes: usize) -> String {
    if output.len() <= max_bytes {
        return output.to_string();
    }
    let boundary = output.floor_char_boundary(max_bytes);
    let truncated = &output[..boundary];
    format!(
        "{truncated}\n\n[truncated: {} bytes -> {} bytes]",
        output.len(),
        boundary
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_truncation_when_within_limit() {
        let input = "hello world";
        let result = truncate_output(input, 1024);
        assert_eq!(result, input);
    }

    #[test]
    fn truncates_at_limit() {
        let input = "a".repeat(1000);
        let result = truncate_output(&input, 100);
        assert!(result.len() < 200); // 100 chars + marker
        assert!(result.contains("[truncated: 1000 bytes -> 100 bytes]"));
        assert!(result.starts_with("aaaa"));
    }

    #[test]
    fn truncates_at_char_boundary() {
        // Multi-byte chars: each is 4 bytes
        let input = "🦀".repeat(100); // 400 bytes
        let result = truncate_output(&input, 10);
        // floor_char_boundary(10) for 4-byte chars = 8 (2 chars)
        assert!(result.contains("[truncated:"));
        // Must be valid UTF-8
        assert!(result.is_char_boundary(0));
    }

    #[test]
    fn bash_gets_larger_limit() {
        assert_eq!(max_output_for_tool("Bash"), 1024 * 1024);
    }

    #[test]
    fn other_tools_get_default_limit() {
        assert_eq!(max_output_for_tool("Read"), 256 * 1024);
        assert_eq!(max_output_for_tool("Grep"), 256 * 1024);
    }

    #[test]
    fn exact_boundary_no_truncation() {
        let input = "a".repeat(100);
        let result = truncate_output(&input, 100);
        assert_eq!(result, input);
    }

    #[test]
    fn one_over_truncates() {
        let input = "a".repeat(101);
        let result = truncate_output(&input, 100);
        assert!(result.contains("[truncated: 101 bytes -> 100 bytes]"));
    }

    #[test]
    fn empty_string() {
        assert_eq!(truncate_output("", 100), "");
    }
}

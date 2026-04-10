/// Split combined diff output by file, returning (path, `diff_chunk`) pairs.
pub fn split_diff_by_file(diff: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    let mut current_path: Option<String> = None;
    let mut current_chunk = String::new();

    for line in diff.lines() {
        if let Some(rest) = line.strip_prefix("diff --git a/") {
            if let Some(path) = current_path.take() {
                let _ = map.insert(path, current_chunk.clone());
            }
            current_chunk.clear();
            if let Some(b_idx) = rest.rfind(" b/") {
                current_path = Some(rest[b_idx + 3..].to_string());
            }
        } else if current_path.is_some() {
            if !current_chunk.is_empty() {
                current_chunk.push('\n');
            }
            current_chunk.push_str(line);
        }
    }

    if let Some(path) = current_path {
        let _ = map.insert(path, current_chunk);
    }
    map
}

/// Count additions and deletions in a diff chunk.
pub fn count_diff_stats(chunk: &str) -> (usize, usize) {
    let mut additions = 0;
    let mut deletions = 0;
    for line in chunk.lines() {
        if line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
    }
    (additions, deletions)
}

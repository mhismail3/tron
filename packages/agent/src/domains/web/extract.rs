//! Deterministic readable-text extraction for fetched web source evidence.

const EXTRACTOR_ID: &str = "tron.web.html_readable_text";
const EXTRACTOR_VERSION: &str = "1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExtractedText {
    pub(crate) text: String,
    pub(crate) mode: &'static str,
    pub(crate) extractor_id: &'static str,
    pub(crate) extractor_version: &'static str,
    pub(crate) title: Option<String>,
    pub(crate) extracted_text_bytes: usize,
    pub(crate) binary_body_omitted: bool,
}

pub(crate) fn extract_response_text(content_type: Option<&str>, bytes: &[u8]) -> ExtractedText {
    if is_html_like_content_type(content_type) {
        return extract_html(bytes);
    }
    if is_textual_content_type(content_type) {
        let text = String::from_utf8_lossy(bytes).into_owned();
        let extracted_text_bytes = text.len();
        return ExtractedText {
            text,
            mode: "plain_text",
            extractor_id: "tron.web.plain_text",
            extractor_version: EXTRACTOR_VERSION,
            title: None,
            extracted_text_bytes,
            binary_body_omitted: false,
        };
    }
    ExtractedText {
        text: String::new(),
        mode: "binary_omitted",
        extractor_id: "tron.web.binary_omitted",
        extractor_version: EXTRACTOR_VERSION,
        title: None,
        extracted_text_bytes: 0,
        binary_body_omitted: true,
    }
}

pub(crate) fn is_textual_content_type(content_type: Option<&str>) -> bool {
    let Some(content_type) = content_type else {
        return true;
    };
    let lower = content_type.to_ascii_lowercase();
    lower.starts_with("text/")
        || lower.contains("json")
        || lower.contains("xml")
        || lower.contains("javascript")
        || lower.contains("x-www-form-urlencoded")
}

fn is_html_like_content_type(content_type: Option<&str>) -> bool {
    let Some(content_type) = content_type else {
        return false;
    };
    content_type
        .split([',', ';'])
        .map(|part| part.trim().to_ascii_lowercase())
        .any(|media_type| {
            matches!(
                media_type.as_str(),
                "text/html" | "application/xhtml+xml" | "application/html"
            ) || media_type.ends_with("+html")
        })
}

fn extract_html(bytes: &[u8]) -> ExtractedText {
    let html = String::from_utf8_lossy(bytes);
    let mut text = String::new();
    let mut title = String::new();
    let mut tag = String::new();
    let mut skip_stack: Vec<String> = Vec::new();
    let mut in_title = false;
    let mut in_tag = false;
    let mut chars = html.chars().peekable();

    while let Some(ch) = chars.next() {
        if in_tag {
            if ch == '>' {
                handle_tag(&tag, &mut skip_stack, &mut in_title, &mut text);
                tag.clear();
                in_tag = false;
            } else {
                tag.push(ch);
            }
            continue;
        }

        if ch == '<' {
            in_tag = true;
            continue;
        }

        if in_title {
            title.push(ch);
        } else if skip_stack.is_empty() {
            text.push(ch);
        }
    }

    if in_tag && !tag.is_empty() {
        text.push('<');
        text.push_str(&tag);
    }

    let text = normalize_readable_text(&decode_html_entities(&text));
    let title = normalize_readable_text(&decode_html_entities(&title));
    let title = if title.is_empty() { None } else { Some(title) };
    let extracted_text_bytes = text.len();
    ExtractedText {
        text,
        mode: "html_readable_text",
        extractor_id: EXTRACTOR_ID,
        extractor_version: EXTRACTOR_VERSION,
        title,
        extracted_text_bytes,
        binary_body_omitted: false,
    }
}

fn handle_tag(
    raw_tag: &str,
    skip_stack: &mut Vec<String>,
    in_title: &mut bool,
    output: &mut String,
) {
    let trimmed = raw_tag.trim();
    if trimmed.is_empty()
        || trimmed.starts_with('!')
        || trimmed.starts_with('?')
        || trimmed.starts_with("!--")
    {
        return;
    }

    let closing = trimmed.starts_with('/');
    let body = trimmed.trim_start_matches('/').trim_start();
    let name = body
        .split(|ch: char| ch.is_ascii_whitespace() || matches!(ch, '/' | '>'))
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    if name.is_empty() {
        return;
    }

    if name == "title" {
        *in_title = !closing;
        return;
    }

    if closing {
        if skip_stack.last().is_some_and(|tag| tag == &name) {
            skip_stack.pop();
        } else if let Some(index) = skip_stack.iter().rposition(|tag| tag == &name) {
            skip_stack.truncate(index);
        }
        if skip_stack.is_empty() && is_block_tag(&name) {
            output.push(' ');
        }
        return;
    }

    let self_closing = trimmed.ends_with('/');
    if is_skipped_tag(&name) && !self_closing {
        skip_stack.push(name);
        return;
    }
    if skip_stack.is_empty() && (is_block_tag(&name) || name == "br") {
        output.push(' ');
    }
}

fn is_skipped_tag(name: &str) -> bool {
    matches!(
        name,
        "script"
            | "style"
            | "noscript"
            | "template"
            | "svg"
            | "canvas"
            | "object"
            | "embed"
            | "iframe"
            | "head"
            | "nav"
            | "aside"
            | "form"
            | "footer"
    )
}

fn is_block_tag(name: &str) -> bool {
    matches!(
        name,
        "address"
            | "article"
            | "blockquote"
            | "body"
            | "dd"
            | "details"
            | "dialog"
            | "div"
            | "dl"
            | "dt"
            | "fieldset"
            | "figcaption"
            | "figure"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "header"
            | "hr"
            | "li"
            | "main"
            | "ol"
            | "p"
            | "pre"
            | "section"
            | "table"
            | "td"
            | "th"
            | "tr"
            | "ul"
    )
}

fn normalize_readable_text(value: &str) -> String {
    let mut output = String::new();
    let mut pending_space = false;
    for ch in value.chars() {
        if ch.is_whitespace() {
            pending_space = true;
            continue;
        }
        if pending_space && !output.is_empty() {
            output.push(' ');
        }
        pending_space = false;
        output.push(ch);
    }
    output
}

fn decode_html_entities(value: &str) -> String {
    let mut output = String::new();
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '&' {
            output.push(ch);
            continue;
        }
        let mut entity = String::new();
        while let Some(next) = chars.peek().copied() {
            if next == ';' {
                chars.next();
                break;
            }
            if entity.len() >= 16 || next.is_whitespace() || next == '&' {
                break;
            }
            entity.push(next);
            chars.next();
        }
        if let Some(decoded) = decode_entity(&entity) {
            output.push(decoded);
        } else {
            output.push('&');
            output.push_str(&entity);
            if entity.len() < 16 {
                output.push(';');
            }
        }
    }
    output
}

fn decode_entity(entity: &str) -> Option<char> {
    match entity {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" | "#39" => Some('\''),
        "nbsp" => Some(' '),
        _ if entity.starts_with("#x") || entity.starts_with("#X") => {
            u32::from_str_radix(&entity[2..], 16)
                .ok()
                .and_then(char::from_u32)
        }
        _ if entity.starts_with('#') => entity[1..].parse::<u32>().ok().and_then(char::from_u32),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_extraction_removes_noise_and_preserves_body_text() {
        let extracted = extract_response_text(
            Some("text/html; charset=utf-8"),
            br#"
            <html>
              <head><title>Example &amp; Title</title><style>.x{}</style></head>
              <body>
                <nav>skip nav</nav>
                <main><h1>Alpha</h1><p>Beta&nbsp;Gamma</p></main>
                <script>secret()</script><footer>skip footer</footer>
              </body>
            </html>
            "#,
        );
        assert_eq!(extracted.mode, "html_readable_text");
        assert_eq!(extracted.title, Some("Example & Title".to_owned()));
        assert_eq!(extracted.text, "Alpha Beta Gamma");
    }

    #[test]
    fn plain_text_keeps_original_text_mode() {
        let extracted = extract_response_text(Some("application/json"), br#"{"a":true}"#);
        assert_eq!(extracted.mode, "plain_text");
        assert_eq!(extracted.text, r#"{"a":true}"#);
    }
}

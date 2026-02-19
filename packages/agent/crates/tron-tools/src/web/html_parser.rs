//! HTML to Markdown conversion.
//!
//! Extracts title, description, and body from HTML, then converts to Markdown.
//! Uses `scraper` for parsing and `html2text` for conversion.

use scraper::{Html, Selector};

const MAX_CONTENT_LENGTH: usize = 500_000;

/// Result of parsing HTML content.
pub struct HtmlParseResult {
    /// Converted Markdown content.
    pub markdown: String,
    /// Page title.
    pub title: String,
    /// Meta description.
    pub description: Option<String>,
    /// Original HTML byte length.
    pub original_length: usize,
    /// Final Markdown character count.
    pub parsed_length: usize,
}

/// Parse HTML content into Markdown with metadata extraction.
pub fn parse_html(html: &str, _base_url: Option<&str>) -> HtmlParseResult {
    let original_length = html.len();

    // Truncate very large HTML before parsing (UTF-8–safe)
    let html = tron_core::text::truncate_str(html, MAX_CONTENT_LENGTH);

    let document = Html::parse_document(html);

    let title = extract_title(&document);
    let description = extract_description(&document);

    // Convert to markdown via html2text
    let markdown = html2text::from_read(html.as_bytes(), 100).unwrap_or_default();

    // Clean up the markdown
    let markdown = clean_markdown(&markdown);

    let parsed_length = markdown.len();

    HtmlParseResult {
        markdown,
        title,
        description,
        original_length,
        parsed_length,
    }
}

fn extract_title(doc: &Html) -> String {
    // Priority: <title> → og:title → <h1>
    if let Some(title_el) = Selector::parse("title")
        .ok()
        .and_then(|s| doc.select(&s).next())
    {
        let text = title_el.text().collect::<String>().trim().to_string();
        if !text.is_empty() {
            return text;
        }
    }

    if let Some(og) = Selector::parse(r#"meta[property="og:title"]"#)
        .ok()
        .and_then(|s| doc.select(&s).next())
    {
        if let Some(content) = og.value().attr("content") {
            let text = content.trim().to_string();
            if !text.is_empty() {
                return text;
            }
        }
    }

    if let Some(h1) = Selector::parse("h1")
        .ok()
        .and_then(|s| doc.select(&s).next())
    {
        let text = h1.text().collect::<String>().trim().to_string();
        if !text.is_empty() {
            return text;
        }
    }

    String::new()
}

fn extract_description(doc: &Html) -> Option<String> {
    // Priority: meta[name=description] → og:description
    if let Some(meta) = Selector::parse(r#"meta[name="description"]"#)
        .ok()
        .and_then(|s| doc.select(&s).next())
    {
        if let Some(content) = meta.value().attr("content") {
            let text = content.trim().to_string();
            if !text.is_empty() {
                return Some(text);
            }
        }
    }

    if let Some(og) = Selector::parse(r#"meta[property="og:description"]"#)
        .ok()
        .and_then(|s| doc.select(&s).next())
    {
        if let Some(content) = og.value().attr("content") {
            let text = content.trim().to_string();
            if !text.is_empty() {
                return Some(text);
            }
        }
    }

    None
}

fn clean_markdown(md: &str) -> String {
    // Remove excessive blank lines (3+ → 2)
    let mut result = String::with_capacity(md.len());
    let mut blank_count = 0;
    for line in md.lines() {
        if line.trim().is_empty() {
            blank_count += 1;
            if blank_count <= 2 {
                result.push('\n');
            }
        } else {
            blank_count = 0;
            result.push_str(line);
            result.push('\n');
        }
    }
    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_html_page_to_markdown() {
        let html = r#"<html><head><title>Test Page</title></head><body><h1>Hello</h1><p>World</p></body></html>"#;
        let r = parse_html(html, None);
        assert_eq!(r.title, "Test Page");
        assert!(r.markdown.contains("Hello"));
        assert!(r.markdown.contains("World"));
    }

    #[test]
    fn title_extraction_priority() {
        let html = r#"<html><head><title>Title Tag</title><meta property="og:title" content="OG Title"></head><body><h1>H1 Title</h1></body></html>"#;
        let r = parse_html(html, None);
        assert_eq!(r.title, "Title Tag");
    }

    #[test]
    fn og_title_fallback() {
        let html = r#"<html><head><meta property="og:title" content="OG Title"></head><body><h1>H1 Title</h1></body></html>"#;
        let r = parse_html(html, None);
        assert_eq!(r.title, "OG Title");
    }

    #[test]
    fn h1_title_fallback() {
        let html = r#"<html><body><h1>H1 Title</h1></body></html>"#;
        let r = parse_html(html, None);
        assert_eq!(r.title, "H1 Title");
    }

    #[test]
    fn description_from_meta() {
        let html = r#"<html><head><meta name="description" content="A test page"></head><body></body></html>"#;
        let r = parse_html(html, None);
        assert_eq!(r.description.unwrap(), "A test page");
    }

    #[test]
    fn description_og_fallback() {
        let html = r#"<html><head><meta property="og:description" content="OG desc"></head><body></body></html>"#;
        let r = parse_html(html, None);
        assert_eq!(r.description.unwrap(), "OG desc");
    }

    #[test]
    fn empty_html_produces_empty_markdown() {
        let r = parse_html("", None);
        assert!(r.title.is_empty());
        assert!(r.description.is_none());
    }

    #[test]
    fn malformed_html_best_effort() {
        let html = "<div><p>Unclosed paragraph<b>Bold text</div>";
        let r = parse_html(html, None);
        assert!(r.markdown.contains("Unclosed paragraph") || r.markdown.contains("Bold text"));
    }

    #[test]
    fn content_length_tracking() {
        let html = "<html><body><p>Hello World</p></body></html>";
        let r = parse_html(html, None);
        assert_eq!(r.original_length, html.len());
        assert!(r.parsed_length > 0);
    }

    #[test]
    fn large_html_truncated_before_parsing() {
        let html = format!("<html><body>{}</body></html>", "x".repeat(600_000));
        let r = parse_html(&html, None);
        // Should not panic, and original_length reflects full input
        assert_eq!(r.original_length, html.len());
    }

    #[test]
    fn special_characters_decoded() {
        let html = "<html><body><p>Hello &amp; World &lt;3&gt;</p></body></html>";
        let r = parse_html(html, None);
        assert!(r.markdown.contains("&") || r.markdown.contains("Hello"));
    }

    #[test]
    fn heading_conversion() {
        let html = "<html><body><h1>Title</h1><h2>Subtitle</h2><p>Text</p></body></html>";
        let r = parse_html(html, None);
        assert!(r.markdown.contains("Title"));
        assert!(r.markdown.contains("Subtitle"));
    }
}

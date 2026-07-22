//! Bounded trusted-local HTTP and HTTPS retrieval.

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::runtime::WorkerRuntime;
use super::support::{MAX_FILE_BYTES, bounded_usize, decode_bounded_utf8, required_string};

const DEFAULT_WEB_FETCH_BYTES: usize = 1_048_576;

pub(in crate::domains::worker_kernel) async fn web_fetch(
    invocation: &Invocation,
    _runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let url = required_string(&invocation.payload, "url")?;
    let parsed = url::Url::parse(&url).map_err(|error| format!("invalid URL: {error}"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("web_fetch supports only HTTP and HTTPS".to_owned());
    }
    let max_bytes = bounded_usize(
        &invocation.payload,
        "maxBytes",
        DEFAULT_WEB_FETCH_BYTES,
        MAX_FILE_BYTES,
    );
    let mut response = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|error| error.to_string())?
        .get(parsed)
        .send()
        .await
        .map_err(|error| format!("fetch URL: {error}"))?;
    let status = response.status();
    let final_url = response.url().to_string();
    let content_length = response.content_length();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let mut content =
        Vec::with_capacity(content_length.unwrap_or_default().min(max_bytes as u64) as usize);
    let mut observed_bytes = 0_u64;
    let mut truncated = content_length.is_some_and(|length| length > max_bytes as u64);
    while content.len() <= max_bytes {
        let Some(chunk) = response.chunk().await.map_err(|error| error.to_string())? else {
            break;
        };
        observed_bytes = observed_bytes.saturating_add(chunk.len() as u64);
        let remaining = max_bytes.saturating_add(1).saturating_sub(content.len());
        content.extend_from_slice(&chunk[..remaining.min(chunk.len())]);
        if content.len() > max_bytes || chunk.len() > remaining {
            truncated = true;
            break;
        }
    }
    content.truncate(max_bytes);
    let content = decode_bounded_utf8(content, truncated, Path::new(&final_url))?;
    Ok(json!({
        "url": final_url,
        "status": status.as_u16(),
        "contentType": content_type,
        "contentLength": content_length,
        "observedBytes": observed_bytes,
        "retainedBytes": content.len(),
        "truncated": truncated,
        "content": content,
    }))
}

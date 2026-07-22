//! Bounded trusted-local HTTP and HTTPS retrieval.

use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::Invocation;

use super::super::runtime::WorkerRuntime;
use super::support::{MAX_FILE_BYTES, bounded_usize, decode_bounded_utf8, required_string};

const DEFAULT_WEB_FETCH_BYTES: usize = 128 * 1_024;
const DEFAULT_WEB_FETCH_TIMEOUT_SECONDS: usize = 30;
const MAX_WEB_FETCH_TIMEOUT_SECONDS: usize = 120;

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
    let timeout_seconds = bounded_usize(
        &invocation.payload,
        "timeoutSeconds",
        DEFAULT_WEB_FETCH_TIMEOUT_SECONDS,
        MAX_WEB_FETCH_TIMEOUT_SECONDS,
    );
    fetch_url(parsed, max_bytes, timeout_seconds).await
}

async fn fetch_url(
    parsed: url::Url,
    max_bytes: usize,
    timeout_seconds: usize,
) -> Result<Value, String> {
    let mut response = reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout_seconds as u64))
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
    let content_sha256 = format!("sha256:{}", hex::encode(Sha256::digest(&content)));
    let content = decode_bounded_utf8(content, truncated, Path::new(&final_url))?;
    Ok(json!({
        "url": final_url,
        "status": status.as_u16(),
        "contentType": content_type,
        "contentLength": content_length,
        "observedBytes": observed_bytes,
        "retainedBytes": content.len(),
        "contentSha256": content_sha256,
        "truncated": truncated,
        "content": content,
    }))
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    #[tokio::test]
    async fn default_fetch_budget_is_context_bounded_and_content_addressed() {
        let body = vec![b'x'; DEFAULT_WEB_FETCH_BYTES + 64];
        let expected_hash = format!(
            "sha256:{}",
            hex::encode(Sha256::digest(&body[..DEFAULT_WEB_FETCH_BYTES]))
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let response_body = body.clone();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0_u8; 1024];
            let _ = socket.read(&mut request).await.unwrap();
            let headers = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                response_body.len()
            );
            socket.write_all(headers.as_bytes()).await.unwrap();
            let _ = socket.write_all(&response_body).await;
        });

        let value = fetch_url(
            url::Url::parse(&format!("http://{address}/large.txt")).unwrap(),
            DEFAULT_WEB_FETCH_BYTES,
            DEFAULT_WEB_FETCH_TIMEOUT_SECONDS,
        )
        .await
        .unwrap();

        assert_eq!(value["retainedBytes"], DEFAULT_WEB_FETCH_BYTES);
        assert_eq!(value["truncated"], true);
        assert_eq!(value["contentSha256"], expected_hash);
        assert_eq!(
            value["content"].as_str().unwrap().len(),
            DEFAULT_WEB_FETCH_BYTES
        );
        server.await.unwrap();
    }
}

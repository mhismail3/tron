//! `Bash` tool — shell command execution with timeout and danger detection.
//!
//! Spawns `bash -c <command>` in the working directory. Detects dangerous
//! patterns (rm -rf /, fork bombs, dd to device, etc.) and blocks them.
//! Output is truncated if it exceeds the character budget. Large outputs
//! (> `INLINE_OUTPUT_LIMIT`) are stored as blobs and replaced with
//! head + tail inline.

use std::sync::{Arc, LazyLock};

use async_trait::async_trait;
use regex::Regex;

static DANGER_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/($|\s|;|\|)",
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/\*",
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/(usr|etc|var|home|boot|dev|proc|sys)\b",
        r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:",
        r"dd\s+.*of=/dev/[sh]d",
        r"mkfs\.\w+\s+/dev/",
        r"chmod\s+(-[^\s]+\s+)*777\s+/$",
        r">\s*/dev/[sh]d",
    ]
    .iter()
    .map(|p| Regex::new(p).expect("danger pattern must compile"))
    .collect()
});
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::cache::{CacheKey, KeyExtractor, ServerCache};
use crate::tools::errors::ToolError;
use crate::tools::skill_context::{RateLimiter, ResolvedSkillContext, SkillContextResolver};
use crate::tools::traits::{BlobStore, ProcessOptions, ProcessRunner, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::truncation::estimate_tokens;
use crate::tools::utils::validation::{get_optional_bool, get_optional_string, get_optional_u64, validate_required_string};

const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MAX_TIMEOUT_MS: u64 = 3_600_000;
const PTY_MAX_TIMEOUT_MS: u64 = 120_000;
const INTERACTIVE_DEFAULT_TIMEOUT_MS: u64 = 30_000;
const MAX_OUTPUT_CHARS: usize = 400_000;
const INLINE_OUTPUT_LIMIT: usize = 30_000;
const BLOB_HEAD_CHARS: usize = 20_000;
const BLOB_TAIL_CHARS: usize = 8_000;

/// The `Bash` tool executes shell commands.
pub struct BashTool {
    runner: Arc<dyn ProcessRunner>,
    blob_store: Option<Arc<dyn BlobStore>>,
    /// Default Docker image for sandbox mode (from settings).
    sandbox_default_image: String,
    /// Whether Docker sandbox has network by default (from settings).
    sandbox_network_enabled: bool,
    /// Resolves skill names to display + guards metadata.
    skill_resolver: Option<Arc<dyn SkillContextResolver>>,
    /// General-purpose server cache for skill guards.
    server_cache: Option<Arc<ServerCache>>,
    /// Per-skill rate limiter.
    rate_limiter: RateLimiter,
}

impl BashTool {
    /// Create a new `Bash` tool with the given process runner and optional blob store.
    pub fn new(runner: Arc<dyn ProcessRunner>, blob_store: Option<Arc<dyn BlobStore>>) -> Self {
        Self {
            runner,
            blob_store,
            sandbox_default_image: "ubuntu:latest".to_string(),
            sandbox_network_enabled: true,
            skill_resolver: None,
            server_cache: None,
            rate_limiter: RateLimiter::new(),
        }
    }

    /// Configure sandbox settings (called from factory with settings values).
    #[must_use]
    pub fn with_sandbox_settings(mut self, default_image: String, network_enabled: bool) -> Self {
        self.sandbox_default_image = default_image;
        self.sandbox_network_enabled = network_enabled;
        self
    }

    /// Set the skill context resolver for guard support.
    #[must_use]
    pub fn with_skill_resolver(mut self, resolver: Arc<dyn SkillContextResolver>) -> Self {
        self.skill_resolver = Some(resolver);
        self
    }

    /// Set the server cache for skill cache guards.
    #[must_use]
    pub fn with_server_cache(mut self, cache: Arc<ServerCache>) -> Self {
        self.server_cache = Some(cache);
        self
    }

    fn check_dangerous(command: &str) -> Option<String> {
        for pattern in &*DANGER_PATTERNS {
            if pattern.is_match(command) {
                return Some("Potentially destructive command pattern detected".into());
            }
        }
        None
    }

    /// Build the `skillContext` JSON for result details.
    fn build_skill_context_json(&self, ctx: &ResolvedSkillContext) -> Value {
        let mut sc = json!({"skill": ctx.name});
        if let Some(ref display) = ctx.display {
            if let Some(ref label) = display.label {
                sc["label"] = json!(label);
            }
            if let Some(ref icon) = display.icon {
                sc["icon"] = json!(icon);
            }
            if let Some(ref color) = display.color {
                sc["color"] = json!(color);
            }
        }
        sc
    }

    /// Check if a PATH value points to suspicious locations (e.g., /tmp, hidden dirs).
    fn is_suspicious_path(path: &str) -> bool {
        let suspicious = ["/tmp/", "/var/tmp/", "/dev/shm/"];
        for segment in path.split(':') {
            let seg = segment.trim();
            if seg.is_empty() {
                continue;
            }
            // Suspicious: starts with temp dirs or hidden dirs in home
            for prefix in &suspicious {
                if seg.starts_with(prefix) {
                    return true;
                }
            }
            // Suspicious: hidden directory path (e.g., ~/.malware/bin)
            if seg.contains("/.") && !seg.contains("/.tron") && !seg.contains("/.cargo")
                && !seg.contains("/.local") && !seg.contains("/.nvm")
                && !seg.contains("/.npm") && !seg.contains("/.bun")
                && !seg.contains("/.pyenv") && !seg.contains("/.rbenv")
                && !seg.contains("/.rustup") && !seg.contains("/.volta")
                && !seg.contains("/.go") && !seg.contains("/.deno")
            {
                return true;
            }
        }
        false
    }

    /// Redact ptyInput send values for password-like patterns in audit log.
    fn redact_pty_input(pty_input: &[(String, String)]) -> Vec<Value> {
        pty_input
            .iter()
            .map(|(wait, send)| {
                let is_sensitive = is_sensitive_prompt(wait);
                json!({
                    "wait": wait,
                    "send": if is_sensitive { "[REDACTED]" } else { send.as_str() },
                })
            })
            .collect()
    }
}

/// Check if a PTY prompt string indicates sensitive input.
///
/// Uses phrase matching for ambiguous words like "key" to avoid false
/// positives (e.g., "api key" redacts but "keyboard" does not).
fn is_sensitive_prompt(prompt: &str) -> bool {
    let lower = prompt.to_lowercase();
    // Single-word triggers (unambiguous)
    let single_words = ["password", "passphrase", "secret", "token", "credential", "pin"];
    for word in single_words {
        if lower.contains(word) {
            return true;
        }
    }
    // Phrase triggers (disambiguate "key" from "keyboard")
    let phrases = ["api key", "secret key", "ssh key", "private key", "oauth"];
    for phrase in phrases {
        if lower.contains(phrase) {
            return true;
        }
    }
    false
}

/// Find a UTF-8-safe char boundary at or before `target` byte index.
fn safe_char_boundary(s: &str, target: usize) -> usize {
    if target >= s.len() {
        return s.len();
    }
    // floor_char_boundary is nightly-only; use char_indices
    let mut boundary = 0;
    for (i, _) in s.char_indices() {
        if i > target {
            break;
        }
        boundary = i;
    }
    boundary
}

/// Find a UTF-8-safe char boundary at or after `target` byte index (for tail start).
fn safe_char_boundary_ceil(s: &str, target: usize) -> usize {
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

#[async_trait]
impl TronTool for BashTool {
    fn name(&self) -> &str {
        "Bash"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Shell
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Bash",
            "Execute a shell command. Commands that are potentially destructive require confirmation.\n\n\
             Parameters:\n\
             - **command** (required): The shell command to execute.\n\
             - **timeout** (optional): Timeout in milliseconds (default 120000, max 3600000).\n\
             - **description** (optional): Brief description of what the command does.\n\
             - **stdin** (optional): Data to pipe to the command's stdin.\n\
             - **env** (optional): Environment variables as key-value object.\n\
             - **shell** (optional): Shell to use — \"bash\" (default), \"zsh\", or \"sh\".\n\
             - **interactive** (optional): Run in PTY mode for commands that need a terminal.\n\
             - **ptyInput** (optional): Pattern-response pairs for interactive prompts. Array of {wait, send} objects.",
        )
        .required_property("command", json!({"type": "string", "description": "The shell command to execute"}))
        .property("timeout", json!({"type": "number", "description": "Timeout in milliseconds (default 120000, max 3600000)"}))
        .property("description", json!({"type": "string", "description": "Brief description of what the command does"}))
        .property("stdin", json!({"type": "string", "description": "Data to pipe to the command's stdin"}))
        .property("env", json!({"type": "object", "description": "Environment variables", "additionalProperties": {"type": "string"}}))
        .property("shell", json!({"type": "string", "description": "Shell to use", "enum": ["bash", "zsh", "sh"], "default": "bash"}))
        .property("interactive", json!({"type": "boolean", "description": "Run in PTY mode for interactive commands", "default": false}))
        .property("ptyInput", json!({
            "type": "array",
            "description": "Pattern-response pairs for interactive prompts",
            "items": {
                "type": "object",
                "properties": {
                    "wait": {"type": "string", "description": "Pattern to wait for in output"},
                    "send": {"type": "string", "description": "Text to send when pattern matches"}
                },
                "required": ["wait", "send"]
            }
        }))
        .property("sandbox", json!({
            "description": "Run in sandbox. true = lightweight temp dir sandbox, \"docker\" = Docker container sandbox.",
            "oneOf": [
                {"type": "boolean"},
                {"type": "string", "enum": ["docker"]}
            ]
        }))
        .property("sandboxMounts", json!({
            "type": "array",
            "description": "Paths to symlink into the sandbox (read-only)",
            "items": {"type": "string"}
        }))
        .property("skill", json!({
            "type": "string",
            "description": "Skill context for this command. Include the skill name when executing \
             commands guided by a second-order skill. Activates skill-defined guards (output limits, \
             rate limiting, secret injection, caching) and display metadata for the iOS app."
        }))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let command = match validate_required_string(&params, "command", "the shell command") {
            Ok(c) => c,
            Err(e) => return Ok(e),
        };

        // Check dangerous patterns
        if let Some(reason) = Self::check_dangerous(&command) {
            return Ok(error_result(reason));
        }

        let timeout_ms = get_optional_u64(&params, "timeout")
            .unwrap_or(DEFAULT_TIMEOUT_MS)
            .min(MAX_TIMEOUT_MS);
        let description = get_optional_string(&params, "description");

        // Parse env vars from params
        let mut env_vars: std::collections::HashMap<String, String> = params
            .get("env")
            .and_then(Value::as_object)
            .map(|obj| {
                obj.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();

        // Guard: block suspicious PATH overrides
        if let Some(path_val) = env_vars.get("PATH")
            && Self::is_suspicious_path(path_val)
        {
            return Ok(error_result(
                "Blocked: env overrides PATH to a suspicious location. \
                 Use absolute paths to binaries instead of modifying PATH.",
            ));
        }

        let shell = get_optional_string(&params, "shell")
            .unwrap_or_else(|| "bash".to_string());

        // Validate shell
        let shell = match shell.as_str() {
            "bash" | "zsh" | "sh" => shell,
            _ => "bash".to_string(),
        };

        let stdin = get_optional_string(&params, "stdin");
        let interactive = get_optional_bool(&params, "interactive").unwrap_or(false);

        // Parse ptyInput pattern-response pairs
        let pty_input: Vec<(String, String)> = params
            .get("ptyInput")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|item| {
                        let wait = item.get("wait")?.as_str()?.to_string();
                        let send = item.get("send")?.as_str()?.to_string();
                        Some((wait, send))
                    })
                    .collect()
            })
            .unwrap_or_default();

        // Interactive mode: shorter default timeout, capped at PTY_MAX_TIMEOUT_MS
        let timeout_ms = if interactive {
            let base = get_optional_u64(&params, "timeout")
                .unwrap_or(INTERACTIVE_DEFAULT_TIMEOUT_MS);
            base.min(PTY_MAX_TIMEOUT_MS)
        } else {
            timeout_ms
        };

        // ── Skill context resolution ─────────────────────────────────
        let skill_name = get_optional_string(&params, "skill");
        let skill_ctx: Option<ResolvedSkillContext> = skill_name.as_ref().and_then(|name| {
            self.skill_resolver
                .as_ref()
                .and_then(|r| r.resolve(name))
        });

        // ── Pre-execution guards ────────────────────────────────────
        if let Some(ref ctx_s) = skill_ctx {
            if let Some(ref guards) = ctx_s.guards {
                // Rate limiting
                if let Some(rate_ms) = guards.rate_limit_ms {
                    if let Err(remaining) = self.rate_limiter.check(&ctx_s.name, rate_ms) {
                        return Ok(TronToolResult {
                            content: ToolResultBody::Blocks(vec![
                                crate::core::content::ToolResultContent::text(format!(
                                    "Rate limited for skill '{}'. Please wait {}ms before the next call.",
                                    ctx_s.name, remaining
                                )),
                            ]),
                            details: Some(json!({
                                "command": command,
                                "rateLimited": true,
                                "remainingMs": remaining,
                                "skillContext": self.build_skill_context_json(ctx_s),
                            })),
                            is_error: None,
                            stop_turn: None,
                        });
                    }
                }

                // Secret injection
                if let Some(ref secrets) = guards.secrets {
                    for secret in secrets {
                        // In production, we'd read from settings. For now, we inject
                        // from the process environment as a fallback mechanism.
                        // The actual settings integration happens in Phase 8.
                        if let Ok(val) = std::env::var(&secret.env) {
                            let _ = env_vars.insert(secret.env.clone(), val);
                        }
                    }
                }

                // Cache check
                if let Some(ref cache_cfg) = guards.cache {
                    if let Some(ref cache) = self.server_cache {
                        let extractor = KeyExtractor::from_str_value(&cache_cfg.key_extractor);
                        let cache_key = CacheKey::new(&ctx_s.name, &command, &extractor);
                        if let Some(cached) = cache.get(&cache_key, cache_cfg.ttl) {
                            return Ok(TronToolResult {
                                content: ToolResultBody::Blocks(vec![
                                    crate::core::content::ToolResultContent::text(&cached),
                                ]),
                                details: Some(json!({
                                    "command": command,
                                    "cacheHit": true,
                                    "durationMs": 0,
                                    "skillContext": self.build_skill_context_json(ctx_s),
                                })),
                                is_error: None,
                                stop_turn: None,
                            });
                        }
                    }
                }
            }
        }

        // Parse sandbox config
        let sandbox_mode = params.get("sandbox");
        let sandbox_mounts: Vec<String> = params
            .get("sandboxMounts")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();

        // If sandbox mode is enabled, create a sandbox workspace and override working_directory
        // Track which sandbox mode is active for details JSON
        let mut active_sandbox_mode: Option<&str> = None;
        let sandbox_workspace = if let Some(sandbox_val) = sandbox_mode {
            // Handle both boolean true and string "true" from LLMs
            let is_lightweight = sandbox_val.as_bool() == Some(true)
                || sandbox_val.as_str() == Some("true");
            let is_docker = sandbox_val.as_str() == Some("docker");

            if is_lightweight {
                active_sandbox_mode = Some("lightweight");
                let config = crate::tools::system::sandbox::SandboxConfig {
                    copy_paths: Vec::new(),
                    readonly_mounts: sandbox_mounts,
                };
                match crate::tools::system::sandbox::SandboxWorkspace::create(&config).await {
                    Ok(ws) => Some(ws),
                    Err(e) => return Ok(error_result(format!("Failed to create sandbox: {e}"))),
                }
            } else if is_docker {
                // Docker sandbox: build and run via docker command
                // Apply settings: use configured default image and network
                let docker_config = crate::tools::system::sandbox::DockerSandboxConfig {
                    image: self.sandbox_default_image.clone(),
                    mounts: sandbox_mounts.iter().map(|m| (m.clone(), m.clone(), "ro".to_string())).collect(),
                    network: self.sandbox_network_enabled,
                    ..Default::default()
                };
                if let Err(e) = crate::tools::system::sandbox::check_docker_available().await {
                    return Ok(error_result(e));
                }
                let docker_cmd = crate::tools::system::sandbox::build_docker_command(&command, &docker_config);
                // Replace command with docker command, run normally
                let opts = ProcessOptions {
                    working_directory: ctx.working_directory.clone(),
                    timeout_ms,
                    cancellation: ctx.cancellation.clone(),
                    env: env_vars,
                    stdin,
                    shell,
                    interactive,
                    pty_input,
                    output_tx: ctx.output_tx.clone(),
                };
                let docker_output = self.runner.run_command(&docker_cmd, &opts).await?;
                let mut combined = docker_output.stdout;
                if !docker_output.stderr.is_empty() {
                    if !combined.is_empty() { combined.push('\n'); }
                    combined.push_str(&docker_output.stderr);
                }
                let is_error = if docker_output.exit_code != 0 { Some(true) } else { None };
                // NOTE: Docker early return bypasses post-execution skill guards
                // (cache store, output limiting, skillContext enrichment).
                // Pre-execution guards (rate limit, cache check) still apply.
                return Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(&combined),
                    ]),
                    details: Some(json!({
                        "command": docker_cmd,
                        "exitCode": docker_output.exit_code,
                        "durationMs": docker_output.duration_ms,
                        "sandbox": "docker",
                        "image": self.sandbox_default_image,
                        "description": description,
                    })),
                    is_error,
                    stop_turn: None,
                });
            } else {
                None
            }
        } else {
            None
        };

        let working_dir = if let Some(ref ws) = sandbox_workspace {
            ws.path.to_string_lossy().to_string()
        } else {
            ctx.working_directory.clone()
        };

        // Capture audit info before moving into opts
        let shell_used = shell.clone();
        let is_interactive = interactive;
        let pty_input_audit = if pty_input.is_empty() {
            None
        } else {
            Some(Self::redact_pty_input(&pty_input))
        };

        let opts = ProcessOptions {
            working_directory: working_dir,
            timeout_ms,
            cancellation: ctx.cancellation.clone(),
            env: env_vars,
            stdin,
            shell,
            interactive,
            pty_input,
            output_tx: ctx.output_tx.clone(),
        };

        let output = self.runner.run_command(&command, &opts).await?;

        // Cleanup sandbox if it was used
        if let Some(ws) = sandbox_workspace {
            let _ = ws.cleanup().await;
        }

        // Combine stdout + stderr
        let mut combined = output.stdout;
        if !output.stderr.is_empty() {
            if !combined.is_empty() {
                combined.push('\n');
            }
            combined.push_str(&output.stderr);
        }

        // Hard-truncate at MAX_OUTPUT_CHARS first
        let original_chars = combined.len();
        let hard_truncated = original_chars > MAX_OUTPUT_CHARS;
        if hard_truncated {
            let boundary = safe_char_boundary(&combined, MAX_OUTPUT_CHARS);
            combined.truncate(boundary);
            combined.push_str("\n... [output truncated]");
        }

        let is_error = if output.exit_code != 0 {
            Some(true)
        } else {
            None
        };

        // Blob storage for large outputs
        let mut blob_id: Option<String> = None;
        if combined.len() > INLINE_OUTPUT_LIMIT {
            // Try to store in blob store
            if let Some(ref store) = self.blob_store {
                match store.store(combined.as_bytes(), "text/plain").await {
                    Ok(id) => blob_id = Some(id),
                    Err(e) => {
                        tracing::warn!(error = %e, "blob store failed, returning head+tail without blob reference");
                    }
                }
            }

            // Build head + tail inline
            let head_end = safe_char_boundary(&combined, BLOB_HEAD_CHARS);
            let tail_start = safe_char_boundary_ceil(&combined, combined.len() - BLOB_TAIL_CHARS);
            let omitted = tail_start - head_end;

            let marker = if let Some(ref id) = blob_id {
                format!("\n\n... [{omitted} chars omitted — stored as {id}] ...\n\n")
            } else {
                format!("\n\n... [{omitted} chars omitted] ...\n\n")
            };

            let mut inline =
                String::with_capacity(head_end + marker.len() + (combined.len() - tail_start));
            inline.push_str(&combined[..head_end]);
            inline.push_str(&marker);
            inline.push_str(&combined[tail_start..]);
            combined = inline;
        }

        let mut details = json!({
            "command": command,
            "exitCode": output.exit_code,
            "durationMs": output.duration_ms,
            "truncated": hard_truncated || blob_id.is_some(),
            "originalChars": original_chars,
            "originalTokens": estimate_tokens(original_chars),
            "finalTokens": estimate_tokens(combined.len()),
            "interrupted": output.interrupted,
            "description": description,
            "blobId": blob_id,
        });
        // Include shell/interactive/ptyInput in details for audit
        if shell_used != "bash" {
            details["shell"] = json!(shell_used);
        }
        if is_interactive {
            details["interactive"] = json!(true);
        }
        if let Some(ref pty_audit) = pty_input_audit {
            details["ptyInput"] = json!(pty_audit);
        }
        if let Some(sandbox) = active_sandbox_mode {
            details["sandbox"] = json!(sandbox);
        }

        // ── Post-execution guards ───────────────────────────────────
        if let Some(ref ctx_s) = skill_ctx {
            if let Some(ref guards) = ctx_s.guards {
                // Cache store (full output before our truncation)
                if let Some(ref cache_cfg) = guards.cache {
                    if let Some(ref cache) = self.server_cache {
                        let extractor = KeyExtractor::from_str_value(&cache_cfg.key_extractor);
                        let cache_key = CacheKey::new(&ctx_s.name, &command, &extractor);
                        let _ = cache.set(cache_key, &combined);
                    }
                }

                // Output line limiting (applied AFTER cache store)
                if let Some(max_lines) = guards.max_output_lines {
                    let lines: Vec<&str> = combined.lines().collect();
                    if lines.len() > max_lines {
                        let truncated_output: String =
                            lines[..max_lines].join("\n");
                        combined = format!(
                            "{truncated_output}\n... [{} lines truncated by skill guard]",
                            lines.len() - max_lines
                        );
                    }
                }

                // Output byte limiting
                if let Some(max_bytes) = guards.max_output_bytes {
                    if combined.len() > max_bytes {
                        let boundary = safe_char_boundary(&combined, max_bytes);
                        combined.truncate(boundary);
                        combined.push_str("\n... [output truncated by skill guard]");
                    }
                }
            }

            // Enrich details with skill context
            details["skillContext"] = self.build_skill_context_json(ctx_s);
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                combined,
            )]),
            details: Some(details),
            is_error,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct MockRunner {
        handler: Box<dyn Fn(&str) -> crate::tools::traits::ProcessOutput + Send + Sync>,
    }

    impl MockRunner {
        fn ok(stdout: &str) -> Self {
            let s = stdout.to_owned();
            Self {
                handler: Box::new(move |_| crate::tools::traits::ProcessOutput {
                    stdout: s.clone(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn with_exit(stdout: &str, exit_code: i32) -> Self {
            let s = stdout.to_owned();
            Self {
                handler: Box::new(move |_| crate::tools::traits::ProcessOutput {
                    stdout: s.clone(),
                    stderr: String::new(),
                    exit_code,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn with_timeout() -> Self {
            Self {
                handler: Box::new(|_| crate::tools::traits::ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 124,
                    duration_ms: 120_000,
                    timed_out: true,
                    interrupted: false,
                }),
            }
        }

        fn with_interrupt() -> Self {
            Self {
                handler: Box::new(|_| crate::tools::traits::ProcessOutput {
                    stdout: "partial output".into(),
                    stderr: String::new(),
                    exit_code: 130,
                    duration_ms: 50,
                    timed_out: false,
                    interrupted: true,
                }),
            }
        }

        fn large_output() -> Self {
            Self {
                handler: Box::new(|_| crate::tools::traits::ProcessOutput {
                    stdout: "x".repeat(500_000),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn sized_output(size: usize) -> Self {
            Self {
                handler: Box::new(move |_| crate::tools::traits::ProcessOutput {
                    stdout: "a".repeat(size),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }
    }

    #[async_trait]
    impl ProcessRunner for MockRunner {
        async fn run_command(
            &self,
            command: &str,
            _opts: &ProcessOptions,
        ) -> Result<crate::tools::traits::ProcessOutput, ToolError> {
            Ok((self.handler)(command))
        }
    }

    struct MockBlobStore {
        stored: Mutex<Vec<Vec<u8>>>,
        call_count: AtomicUsize,
        should_fail: bool,
    }

    impl MockBlobStore {
        fn new() -> Self {
            Self {
                stored: Mutex::new(Vec::new()),
                call_count: AtomicUsize::new(0),
                should_fail: false,
            }
        }

        fn failing() -> Self {
            Self {
                stored: Mutex::new(Vec::new()),
                call_count: AtomicUsize::new(0),
                should_fail: true,
            }
        }

        fn call_count(&self) -> usize {
            self.call_count.load(Ordering::SeqCst)
        }

        fn last_stored_size(&self) -> Option<usize> {
            self.stored.lock().unwrap().last().map(std::vec::Vec::len)
        }
    }

    #[async_trait]
    impl BlobStore for MockBlobStore {
        async fn store(&self, content: &[u8], _mime_type: &str) -> Result<String, ToolError> {
            let _ = self.call_count.fetch_add(1, Ordering::SeqCst);
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "blob store error".into(),
                });
            }
            self.stored.lock().unwrap().push(content.to_vec());
            Ok("blob_test123".into())
        }
    }

    use crate::tools::testutil::{extract_text, make_ctx};

    // ── Existing tests (unchanged behavior, updated constructor) ──

    #[tokio::test]
    async fn simple_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("hello world")), None);
        let r = tool
            .execute(json!({"command": "echo hello"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("hello world"));
    }

    #[tokio::test]
    async fn nonzero_exit_code() {
        let tool = BashTool::new(Arc::new(MockRunner::with_exit("error output", 1)), None);
        let r = tool
            .execute(json!({"command": "false"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert_eq!(r.details.unwrap()["exitCode"], 1);
    }

    #[tokio::test]
    async fn timeout_handling() {
        let tool = BashTool::new(Arc::new(MockRunner::with_timeout()), None);
        let r = tool
            .execute(json!({"command": "sleep 999"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["durationMs"], 120_000);
    }

    #[tokio::test]
    async fn timeout_capped_at_max() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "timeout": 999_999_999}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn default_timeout_when_not_specified() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "ls"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn output_truncation() {
        let tool = BashTool::new(Arc::new(MockRunner::large_output()), None);
        let r = tool
            .execute(json!({"command": "cat bigfile"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("chars omitted"));
        assert!(r.details.unwrap()["truncated"].as_bool().unwrap());
    }

    #[tokio::test]
    async fn missing_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn empty_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": ""}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn cancellation_handling() {
        let tool = BashTool::new(Arc::new(MockRunner::with_interrupt()), None);
        let r = tool
            .execute(json!({"command": "long-running"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["interrupted"].as_bool().unwrap());
        assert_eq!(d["exitCode"], 130);
    }

    #[tokio::test]
    async fn description_stored_in_details() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "description": "list files"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["description"], "list files");
    }

    #[tokio::test]
    async fn details_include_exit_code_and_duration() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("out")), None);
        let r = tool
            .execute(json!({"command": "echo"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["exitCode"], 0);
        assert!(d["durationMs"].as_u64().is_some());
    }

    // Dangerous pattern tests

    #[tokio::test]
    async fn blocks_rm_rf_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "rm -rf /"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("destructive"));
    }

    #[tokio::test]
    async fn blocks_sudo_rm_rf_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "sudo rm -rf /"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_rm_rf_star() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "rm -rf /*"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_fork_bomb() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": ":(){ :|: & };:"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_dd_to_device() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "dd if=/dev/zero of=/dev/sda"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_mkfs() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "mkfs.ext4 /dev/sda"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_chmod_777_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "chmod 777 /"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_redirect_to_device() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "> /dev/sda"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_sudo_rm_usr() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "sudo rm -rf /usr"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn allows_safe_commands() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("output")), None);
        for cmd in ["ls -la", "git status", "rm file.txt", "cat /etc/hosts"] {
            let r = tool
                .execute(json!({"command": cmd}), &make_ctx())
                .await
                .unwrap();
            assert!(r.is_error.is_none(), "Command incorrectly blocked: {cmd}");
        }
    }

    #[test]
    fn all_danger_patterns_compile() {
        assert_eq!(
            DANGER_PATTERNS.len(),
            8,
            "expected 8 danger patterns, got {}",
            DANGER_PATTERNS.len()
        );
    }

    // ── Blob storage tests ──

    #[tokio::test]
    async fn blob_store_called_for_large_output() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(50_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 1);
        let d = r.details.as_ref().unwrap();
        assert_eq!(d["blobId"], "blob_test123");
        let text = extract_text(&r);
        assert!(text.contains("blob_test123"));
    }

    #[tokio::test]
    async fn inline_output_below_threshold() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(10_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "small"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 0);
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    #[tokio::test]
    async fn output_at_exact_threshold_not_blobbed() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(INLINE_OUTPUT_LIMIT)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "exact"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 0);
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    #[tokio::test]
    async fn blob_store_error_graceful_fallback() {
        let store = Arc::new(MockBlobStore::failing());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(50_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 1);
        let d = r.details.as_ref().unwrap();
        assert!(d["blobId"].is_null());
        // Still returns head+tail
        let text = extract_text(&r);
        assert!(text.contains("chars omitted"));
    }

    #[tokio::test]
    async fn no_blob_store_still_truncates() {
        let tool = BashTool::new(Arc::new(MockRunner::sized_output(50_000)), None);
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("chars omitted"));
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    #[tokio::test]
    async fn hard_truncation_before_blob() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(500_000)),
            Some(store.clone()),
        );
        let _r = tool
            .execute(json!({"command": "huge"}), &make_ctx())
            .await
            .unwrap();
        // Content passed to blob store should be ≤ MAX_OUTPUT_CHARS + truncation marker
        let stored_size = store.last_stored_size().unwrap();
        assert!(stored_size <= MAX_OUTPUT_CHARS + 30);
    }

    #[tokio::test]
    async fn head_tail_content_correct() {
        let tool = BashTool::new(Arc::new(MockRunner::sized_output(60_000)), None);
        let r = tool
            .execute(json!({"command": "test"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        // Head should start with 'a' repeated chars (our mock output)
        assert!(text.starts_with("aaaa"));
        // Tail should end with 'a' repeated chars
        assert!(text.ends_with("aaaa"));
        // Should have omission marker in the middle
        assert!(text.contains("chars omitted"));
        // Total should be much less than 60K
        assert!(text.len() < 35_000);
    }

    #[tokio::test]
    async fn head_tail_utf8_safe() {
        // Output with multi-byte chars (emoji) throughout
        let runner = Arc::new(MockRunner {
            handler: Box::new(|_| {
                // 🎉 is 4 bytes each, create enough to exceed INLINE_OUTPUT_LIMIT
                let emoji_str = "🎉".repeat(10_000); // 40K bytes
                crate::tools::traits::ProcessOutput {
                    stdout: emoji_str,
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }),
        });
        let tool = BashTool::new(runner, None);
        let r = tool
            .execute(json!({"command": "emoji"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        // Must be valid UTF-8 (extract_text would panic otherwise)
        assert!(!text.is_empty());
        assert!(text.contains("chars omitted"));
    }

    #[tokio::test]
    async fn blob_details_json_shape() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(50_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["blobId"].is_string());
        assert_eq!(d["blobId"].as_str().unwrap(), "blob_test123");
    }

    #[tokio::test]
    async fn blob_details_null_when_below_threshold() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("small")), None);
        let r = tool
            .execute(json!({"command": "ls"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    // ── New: stdin, env, shell tests ──

    #[tokio::test]
    async fn stdin_passed_through() {
        // Mock that echoes back the command (stdin is used by the runner, not visible here)
        let runner = Arc::new(MockRunner::ok("stdin works"));
        let tool = BashTool::new(runner, None);
        let r = tool
            .execute(
                json!({"command": "cat", "stdin": "hello from stdin"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_vars_in_params() {
        // Verify env vars are passed to ProcessOptions (mock doesn't use them, just verifying no errors)
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo $FOO", "env": {"FOO": "bar", "BAZ": "qux"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn shell_param_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "bash"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn shell_param_zsh() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "zsh"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn shell_param_invalid_defaults_to_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "powershell"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn timeout_max_raised_to_3600s() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        // Should accept up to 3_600_000ms
        let r = tool
            .execute(
                json!({"command": "ls", "timeout": 3_600_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    // ── PTY timeout cap tests ──

    #[tokio::test]
    async fn interactive_default_timeout_30s() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "interactive": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        // Default interactive timeout is 30s (not 120s default)
    }

    #[tokio::test]
    async fn interactive_timeout_capped_at_120s() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        // Even if user requests 600s, PTY caps at 120s
        let r = tool
            .execute(
                json!({"command": "echo test", "interactive": true, "timeout": 600_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn interactive_custom_timeout_within_cap() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        // 60s is within PTY cap, should be accepted
        let r = tool
            .execute(
                json!({"command": "echo test", "interactive": true, "timeout": 60_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    // ── PATH override guardrail tests ──

    #[tokio::test]
    async fn env_path_override_tmp_blocked() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/tmp/evil:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("suspicious"));
    }

    #[tokio::test]
    async fn env_path_override_hidden_dir_blocked() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/home/user/.evil/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn env_path_override_safe_allowed() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/usr/local/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_path_override_cargo_allowed() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/Users/me/.cargo/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_path_override_nvm_allowed() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/Users/me/.nvm/versions/node/v20/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_non_path_vars_unaffected() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo $FOO", "env": {"FOO": "/tmp/evil", "BAR": "test"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none(), "Non-PATH env vars should not be checked");
    }

    // ── ptyInput audit tests ──

    #[tokio::test]
    async fn pty_input_logged_in_details() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({
                    "command": "echo test",
                    "interactive": true,
                    "ptyInput": [{"wait": "continue?", "send": "y\n"}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["interactive"].as_bool().unwrap());
        let pty_audit = d["ptyInput"].as_array().unwrap();
        assert_eq!(pty_audit.len(), 1);
        assert_eq!(pty_audit[0]["wait"], "continue?");
        assert_eq!(pty_audit[0]["send"], "y\n");
    }

    #[tokio::test]
    async fn pty_input_password_redacted() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({
                    "command": "ssh user@host",
                    "interactive": true,
                    "ptyInput": [{"wait": "password:", "send": "secret123\n"}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        let pty_audit = d["ptyInput"].as_array().unwrap();
        assert_eq!(pty_audit[0]["send"], "[REDACTED]");
    }

    #[tokio::test]
    async fn shell_logged_in_details_when_not_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "zsh"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["shell"], "zsh");
    }

    #[tokio::test]
    async fn shell_not_in_details_when_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d.get("shell").is_none() || d["shell"].is_null());
    }

    // ── is_suspicious_path unit tests ──

    #[test]
    fn suspicious_path_tmp() {
        assert!(BashTool::is_suspicious_path("/tmp/evil:/usr/bin"));
    }

    #[test]
    fn suspicious_path_hidden_dir() {
        assert!(BashTool::is_suspicious_path("/home/user/.malware/bin:/usr/bin"));
    }

    #[test]
    fn suspicious_path_var_tmp() {
        assert!(BashTool::is_suspicious_path("/var/tmp/bad:/usr/bin"));
    }

    #[test]
    fn safe_path_standard() {
        assert!(!BashTool::is_suspicious_path("/usr/local/bin:/usr/bin:/bin"));
    }

    #[test]
    fn safe_path_cargo() {
        assert!(!BashTool::is_suspicious_path("/Users/me/.cargo/bin:/usr/bin"));
    }

    #[test]
    fn safe_path_nvm() {
        assert!(!BashTool::is_suspicious_path("/Users/me/.nvm/versions/node/v20/bin"));
    }

    #[test]
    fn safe_path_local() {
        assert!(!BashTool::is_suspicious_path("/Users/me/.local/bin:/usr/bin"));
    }

    // ── redact_pty_input unit tests ──

    #[test]
    fn redact_pty_input_normal() {
        let pairs = vec![("continue?".into(), "y\n".into())];
        let result = BashTool::redact_pty_input(&pairs);
        assert_eq!(result[0]["send"], "y\n");
    }

    #[test]
    fn redact_pty_input_password() {
        let pairs = vec![("Enter password:".into(), "secret\n".into())];
        let result = BashTool::redact_pty_input(&pairs);
        assert_eq!(result[0]["send"], "[REDACTED]");
    }

    #[test]
    fn redact_pty_input_token() {
        let pairs = vec![("API token:".into(), "abc123\n".into())];
        let result = BashTool::redact_pty_input(&pairs);
        assert_eq!(result[0]["send"], "[REDACTED]");
    }

    // ── Sandbox tests ──

    #[tokio::test]
    async fn sandbox_true_boolean_creates_sandbox() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("sandbox output")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "sandbox": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["sandbox"], "lightweight");
    }

    #[tokio::test]
    async fn sandbox_true_string_creates_sandbox() {
        // LLMs sometimes send "true" as a string instead of boolean
        let tool = BashTool::new(Arc::new(MockRunner::ok("sandbox output")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "sandbox": "true"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["sandbox"], "lightweight");
    }

    #[tokio::test]
    async fn sandbox_false_no_sandbox() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "sandbox": false}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d.get("sandbox").is_none() || d["sandbox"].is_null());
    }

    #[tokio::test]
    async fn sandbox_no_param_no_sandbox() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(json!({"command": "ls"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d.get("sandbox").is_none() || d["sandbox"].is_null());
    }

    #[tokio::test]
    async fn sandbox_settings_applied_to_docker() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None)
            .with_sandbox_settings("node:20-alpine".into(), false);
        assert_eq!(tool.sandbox_default_image, "node:20-alpine");
        assert!(!tool.sandbox_network_enabled);
    }

    #[tokio::test]
    async fn sandbox_settings_default_values() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        assert_eq!(tool.sandbox_default_image, "ubuntu:latest");
        assert!(tool.sandbox_network_enabled);
    }

    // ── PTY redaction tests ─────────────────────────────────────

    #[test]
    fn pty_redacts_password() {
        assert!(is_sensitive_prompt("Enter password:"));
        assert!(is_sensitive_prompt("PASSWORD:"));
    }

    #[test]
    fn pty_redacts_passphrase() {
        assert!(is_sensitive_prompt("Enter passphrase for key:"));
    }

    #[test]
    fn pty_redacts_token() {
        assert!(is_sensitive_prompt("Token:"));
    }

    #[test]
    fn pty_redacts_secret() {
        assert!(is_sensitive_prompt("Secret key:"));
    }

    #[test]
    fn pty_redacts_pin() {
        assert!(is_sensitive_prompt("Enter PIN:"));
    }

    #[test]
    fn pty_redacts_api_key() {
        assert!(is_sensitive_prompt("API key:"));
    }

    #[test]
    fn pty_redacts_oauth() {
        assert!(is_sensitive_prompt("OAuth credential:"));
    }

    #[test]
    fn pty_redacts_credential() {
        assert!(is_sensitive_prompt("Enter your credential:"));
    }

    #[test]
    fn pty_does_not_redact_username() {
        assert!(!is_sensitive_prompt("Enter username:"));
    }

    #[test]
    fn pty_does_not_redact_name() {
        assert!(!is_sensitive_prompt("What is your name?"));
    }

    #[test]
    fn pty_does_not_redact_file_path() {
        assert!(!is_sensitive_prompt("Enter file path:"));
    }

    #[test]
    fn pty_does_not_redact_keyboard() {
        // "key" in "keyboard" should NOT trigger
        assert!(!is_sensitive_prompt("Keyboard input:"));
    }

    #[test]
    fn pty_does_not_redact_continue_prompt() {
        assert!(!is_sensitive_prompt("Continue? [y/n]"));
    }

    // ── Phase 3: Skill context tests ────────────────────────────

    use crate::skills::types::{CacheConfig, SkillDisplay, SkillGuards};
    use crate::tools::cache::ServerCache;
    use crate::tools::skill_context::{FnResolver, ResolvedSkillContext};

    fn make_resolver(ctx: ResolvedSkillContext) -> Arc<dyn SkillContextResolver> {
        let ctx = Arc::new(ctx);
        Arc::new(FnResolver(move |name: &str| {
            if name == ctx.name {
                Some((*ctx).clone())
            } else {
                None
            }
        }))
    }

    fn skill_ctx_with_display() -> ResolvedSkillContext {
        ResolvedSkillContext {
            name: "code-search".into(),
            display: Some(SkillDisplay {
                label: Some("Code Search".into()),
                icon: Some("magnifyingglass".into()),
                color: Some("#4A90D9".into()),
            }),
            guards: None,
        }
    }

    fn skill_ctx_with_guards(guards: SkillGuards) -> ResolvedSkillContext {
        ResolvedSkillContext {
            name: "test-skill".into(),
            display: None,
            guards: Some(guards),
        }
    }

    // Schema

    #[test]
    fn schema_includes_skill_parameter() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        assert!(props.contains_key("skill"));
        assert_eq!(props["skill"]["type"], "string");
    }

    // Resolution

    #[tokio::test]
    async fn resolve_valid_skill_enriches_details() {
        let resolver = make_resolver(skill_ctx_with_display());
        let tool = BashTool::new(Arc::new(MockRunner::ok("output")), None)
            .with_skill_resolver(resolver);
        let r = tool
            .execute(json!({"command": "rg pattern", "skill": "code-search"}), &make_ctx())
            .await
            .unwrap();
        let details = r.details.unwrap();
        let sc = &details["skillContext"];
        assert_eq!(sc["skill"], "code-search");
        assert_eq!(sc["label"], "Code Search");
        assert_eq!(sc["icon"], "magnifyingglass");
        assert_eq!(sc["color"], "#4A90D9");
    }

    #[tokio::test]
    async fn resolve_unknown_skill_no_error() {
        let resolver = make_resolver(skill_ctx_with_display());
        let tool = BashTool::new(Arc::new(MockRunner::ok("output")), None)
            .with_skill_resolver(resolver);
        let r = tool
            .execute(json!({"command": "echo hi", "skill": "nonexistent"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        let details = r.details.unwrap();
        assert!(details.get("skillContext").is_none());
        assert!(text.contains("output"));
    }

    #[tokio::test]
    async fn no_skill_param_unchanged_behavior() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("hello")), None);
        let r = tool
            .execute(json!({"command": "echo hi"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        let details = r.details.unwrap();
        assert!(details.get("skillContext").is_none());
        assert!(text.contains("hello"));
    }

    #[tokio::test]
    async fn no_resolver_ignores_skill_param() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("output")), None);
        // No resolver set — skill param silently ignored.
        let r = tool
            .execute(json!({"command": "echo hi", "skill": "anything"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.details.unwrap().get("skillContext").is_none());
    }

    // Rate limiting

    #[tokio::test]
    async fn rate_limit_first_call_passes() {
        let guards = SkillGuards {
            rate_limit_ms: Some(60_000),
            ..Default::default()
        };
        let resolver = make_resolver(skill_ctx_with_guards(guards));
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None)
            .with_skill_resolver(resolver);
        let r = tool
            .execute(json!({"command": "echo hi", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("ok"));
    }

    #[tokio::test]
    async fn rate_limit_blocks_fast_calls() {
        let guards = SkillGuards {
            rate_limit_ms: Some(60_000),
            ..Default::default()
        };
        let resolver = make_resolver(skill_ctx_with_guards(guards));
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None)
            .with_skill_resolver(resolver);

        // First call succeeds.
        tool.execute(json!({"command": "echo 1", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();

        // Second call within 60s should be rate limited.
        let r = tool
            .execute(json!({"command": "echo 2", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        let details = r.details.unwrap();
        assert_eq!(details["rateLimited"], true);
        assert!(text.contains("Rate limited"));
    }

    #[tokio::test]
    async fn rate_limit_per_skill() {
        let guards_a = SkillGuards {
            rate_limit_ms: Some(60_000),
            ..Default::default()
        };
        // Resolver that returns guards for both skill-a and skill-b.
        let resolver = Arc::new(FnResolver(move |name: &str| match name {
            "skill-a" => Some(ResolvedSkillContext {
                name: "skill-a".into(),
                display: None,
                guards: Some(guards_a.clone()),
            }),
            "skill-b" => Some(ResolvedSkillContext {
                name: "skill-b".into(),
                display: None,
                guards: Some(SkillGuards {
                    rate_limit_ms: Some(60_000),
                    ..Default::default()
                }),
            }),
            _ => None,
        }));

        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None)
            .with_skill_resolver(resolver);

        // Call skill-a.
        tool.execute(json!({"command": "echo 1", "skill": "skill-a"}), &make_ctx())
            .await
            .unwrap();

        // skill-b should NOT be rate limited by skill-a.
        let r = tool
            .execute(json!({"command": "echo 2", "skill": "skill-b"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.details.unwrap().get("rateLimited").is_none());
    }

    // Cache

    #[tokio::test]
    async fn cache_miss_executes_and_stores() {
        let guards = SkillGuards {
            cache: Some(CacheConfig {
                ttl: 900,
                key_extractor: "command".into(),
            }),
            ..Default::default()
        };
        let resolver = make_resolver(skill_ctx_with_guards(guards));
        let cache = Arc::new(ServerCache::with_defaults());
        let tool = BashTool::new(Arc::new(MockRunner::ok("fresh result")), None)
            .with_skill_resolver(resolver)
            .with_server_cache(cache.clone());

        let r = tool
            .execute(json!({"command": "echo test", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        let details = r.details.unwrap();
        assert!(text.contains("fresh result"));
        assert!(details.get("cacheHit").is_none());

        // Cache should now have the result.
        assert!(!cache.is_empty());
    }

    #[tokio::test]
    async fn cache_hit_returns_cached() {
        let guards = SkillGuards {
            cache: Some(CacheConfig {
                ttl: 900,
                key_extractor: "command".into(),
            }),
            ..Default::default()
        };
        let resolver = make_resolver(skill_ctx_with_guards(guards));
        let cache = Arc::new(ServerCache::with_defaults());

        // Pre-populate cache.
        let key = crate::tools::cache::CacheKey {
            skill: "test-skill".into(),
            key: "echo test".into(),
        };
        cache.set(key, "cached output");

        let tool = BashTool::new(Arc::new(MockRunner::ok("should not see this")), None)
            .with_skill_resolver(resolver)
            .with_server_cache(cache);

        let r = tool
            .execute(json!({"command": "echo test", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        let details = r.details.unwrap();
        assert!(text.contains("cached output"));
        assert_eq!(details["cacheHit"], true);
    }

    #[tokio::test]
    async fn cache_includes_skill_context_display() {
        let ctx = ResolvedSkillContext {
            name: "test-skill".into(),
            display: Some(SkillDisplay {
                label: Some("Test".into()),
                icon: Some("star".into()),
                color: None,
            }),
            guards: Some(SkillGuards {
                cache: Some(CacheConfig {
                    ttl: 900,
                    key_extractor: "command".into(),
                }),
                ..Default::default()
            }),
        };
        let resolver = make_resolver(ctx);
        let cache = Arc::new(ServerCache::with_defaults());
        let key = crate::tools::cache::CacheKey {
            skill: "test-skill".into(),
            key: "echo hi".into(),
        };
        cache.set(key, "cached");

        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None)
            .with_skill_resolver(resolver)
            .with_server_cache(cache);

        let r = tool
            .execute(json!({"command": "echo hi", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        let details = r.details.unwrap();
        let sc = &details["skillContext"];
        assert_eq!(sc["label"], "Test");
        assert_eq!(sc["icon"], "star");
    }

    // Output limiting

    #[tokio::test]
    async fn output_limited_by_max_lines() {
        let guards = SkillGuards {
            max_output_lines: Some(3),
            ..Default::default()
        };
        let resolver = make_resolver(skill_ctx_with_guards(guards));
        let output = "line1\nline2\nline3\nline4\nline5";
        let tool = BashTool::new(Arc::new(MockRunner::ok(output)), None)
            .with_skill_resolver(resolver);

        let r = tool
            .execute(json!({"command": "cat file", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("line1"));
        assert!(text.contains("line3"));
        assert!(!text.contains("line4"));
        assert!(text.contains("truncated by skill guard"));
    }

    #[tokio::test]
    async fn output_limited_by_max_bytes() {
        let guards = SkillGuards {
            max_output_bytes: Some(10),
            ..Default::default()
        };
        let resolver = make_resolver(skill_ctx_with_guards(guards));
        let tool = BashTool::new(Arc::new(MockRunner::ok("abcdefghijklmnop")), None)
            .with_skill_resolver(resolver);

        let r = tool
            .execute(json!({"command": "echo big", "skill": "test-skill"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("truncated by skill guard"));
        // First 10 bytes should be present.
        assert!(text.contains("abcdefghij"));
    }

    // Regression: existing behavior unchanged

    #[tokio::test]
    async fn danger_check_still_applies_with_skill() {
        let resolver = make_resolver(skill_ctx_with_display());
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None)
            .with_skill_resolver(resolver);
        let r = tool
            .execute(json!({"command": "rm -rf /", "skill": "code-search"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("destructive"));
    }

    #[tokio::test]
    async fn timeout_still_works_with_skill() {
        let resolver = make_resolver(skill_ctx_with_display());
        let tool = BashTool::new(Arc::new(MockRunner::with_timeout()), None)
            .with_skill_resolver(resolver);
        let r = tool
            .execute(json!({"command": "sleep 999", "skill": "code-search"}), &make_ctx())
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["exitCode"], 124);
        // skillContext should still be present even on timeout.
        assert!(details.get("skillContext").is_some());
    }
}

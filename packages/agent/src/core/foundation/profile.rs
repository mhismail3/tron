//! Profile-first execution spec loading.
//!
//! Profiles are the normal control plane for model-facing behavior and harness
//! settings. The managed `default` profile is restorable; user profiles inherit
//! from it and are never silently overwritten.
//!
//! v2 profiles resolve to a typed [`AgentExecutionSpec`]. Runtime modules should
//! consume that effective spec (or helpers backed by it), not hardcoded prompt
//! folders or local/cloud policy constants.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use toml::Value;

use super::paths::{self, dirs, files};

/// Managed profile that defines complete default Tron behavior.
pub const DEFAULT_PROFILE: &str = "default";
/// Standard user-facing profile for normal project/workspace sessions.
pub const NORMAL_PROFILE: &str = "normal";
/// Standard user-facing profile for quick chat sessions.
pub const CHAT_PROFILE: &str = "chat";
/// Standard user-facing profile for local-provider sessions.
pub const LOCAL_PROFILE: &str = "local";
/// Default user overlay profile.
pub const USER_PROFILE: &str = "user";
/// Default credential profile name.
pub const DEFAULT_AUTH_PROFILE: &str = "default";
/// Current profile schema version.
pub const CURRENT_PROFILE_VERSION: &str = "2";

/// Parsed profile document.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ProfileDocument {
    /// Schema version.
    pub version: String,
    /// Profile name.
    pub name: String,
    /// Whether this profile is managed/restorable by Tron.
    pub managed: bool,
    /// User-facing profile category (`base`, `normal`, `chat`, `local`, `custom`).
    pub profile_class: Option<String>,
    /// Parent profiles, resolved in order.
    pub inherits: Vec<String>,
    /// Credential profile selected from `profiles/auth.toml`.
    pub auth_profile: String,
    /// Entrypoints for main chat/local/workflow behavior.
    pub entrypoints: HashMap<String, EntryPointSpec>,
    /// All harness-spawned model/process contracts.
    pub processes: HashMap<String, ProcessSpec>,
    /// Model selection/inheritance policies.
    pub model_policies: HashMap<String, ModelPolicySpec>,
    /// Context assembly policies.
    pub context_policies: HashMap<String, ContextPolicySpec>,
    /// Tool visibility and presentation policies.
    pub tool_policies: HashMap<String, ToolPolicySpec>,
    /// Permission and inheritance policies.
    pub permission_policies: HashMap<String, PermissionPolicySpec>,
    /// Provider-specific presentation/adaptation policies.
    pub provider_policies: HashMap<String, ProviderPolicySpec>,
    /// Provider-independent cache policies.
    pub cache_policies: HashMap<String, CachePolicySpec>,
    /// Structured output contracts for subprocesses.
    pub output_contracts: HashMap<String, OutputContractSpec>,
    /// Auditing policies.
    pub audit_policy: HashMap<String, AuditPolicySpec>,
    /// Profile-owned settings refs.
    pub settings: SettingsSpec,
    /// Auth registry/store refs.
    pub auth: AuthSpec,
}

/// Compatibility name used by older call sites while v2 wiring lands.
pub type ProfileSpec = ProfileDocument;
/// Effective agent execution spec after profile inheritance is resolved.
pub type AgentExecutionSpec = ProfileDocument;

/// Entrypoint policy for a primary runtime surface.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct EntryPointSpec {
    /// Prompt markdown file, relative to the profile directory.
    pub prompt: Option<String>,
    /// Model policy id.
    pub model_policy: String,
    /// Cloud/default context policy id.
    pub context_policy: String,
    /// Optional local-model context policy id.
    pub local_context_policy: Option<String>,
    /// Tool policy id.
    pub tool_policy: String,
    /// Permission policy id.
    pub permission_policy: String,
    /// Provider policy id.
    pub provider_policy: String,
    /// Cache policy id.
    pub cache_policy: String,
    /// Audit policy id.
    pub audit_policy: String,
}

/// Kind of model-backed or harness-backed process.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProcessKind {
    /// Primary user-facing agent.
    #[default]
    Main,
    /// Child agent invoked by the LLM or harness.
    Subagent,
    /// Bounded summarization/retention transform.
    Summarizer,
    /// Hook LLM process.
    Hook,
    /// Automation runner.
    Automation,
    /// Tool-owned worker process.
    ToolWorker,
    /// Non-agentic transform.
    Transform,
}

/// Contract for every subprocess Tron may spawn.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ProcessSpec {
    /// Process kind.
    pub kind: ProcessKind,
    /// Prompt markdown file, relative to the profile directory.
    pub prompt: Option<String>,
    /// Model policy id.
    pub model_policy: String,
    /// Context policy id.
    pub context_policy: String,
    /// Tool policy id.
    pub tool_policy: String,
    /// Permission policy id.
    pub permission_policy: String,
    /// Output contract id.
    pub output_contract: String,
    /// Audit policy id.
    pub audit_policy: String,
    /// Wall-clock timeout in milliseconds.
    pub timeout_ms: Option<u64>,
    /// Blocking timeout before a process is backgrounded. `None` means use the
    /// process default; `blocking = false` means immediate background.
    pub blocking_timeout_ms: Option<u64>,
    /// Whether the process blocks the caller by default.
    pub blocking: Option<bool>,
    /// Maximum LLM turns.
    pub max_turns: Option<u32>,
    /// Maximum child nesting depth.
    pub max_depth: Option<u32>,
    /// Whether tools are inherited from the parent registry.
    pub inherit_tools: Option<bool>,
    /// Strict allowlist applied after inherited tools are loaded.
    pub allowed_tools: Option<Vec<String>>,
    /// Tools denied from the inherited registry.
    pub denied_tools: Vec<String>,
    /// Reasoning level string (`none`, `low`, `medium`, `high`, `xhigh`, `max`).
    pub reasoning: Option<String>,
    /// Working directory override.
    pub working_directory: Option<String>,
    /// How process results are injected back into parent context.
    pub result_injection: Option<String>,
    /// Fallback behavior id/label.
    pub fallback: Option<String>,
    /// Whether this process is audited.
    pub audit: Option<bool>,
}

/// Model inheritance/selection policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ModelPolicySpec {
    /// `sessionDefault`, `inheritParent`, `settingsSubagent`, or explicit.
    pub selection: String,
    /// Optional explicit model id.
    pub model: Option<String>,
    /// Optional provider class (`cloud`, `local`, `any`).
    pub provider_class: Option<String>,
    /// Optional reasoning level.
    pub reasoning: Option<String>,
}

/// Context assembly policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ContextPolicySpec {
    /// Context block manifest file.
    pub blocks: Option<String>,
    /// Provider ids that activate this policy as local.
    pub local_providers: Vec<String>,
    /// Tool policy to use when this context policy is active.
    pub tool_policy: Option<String>,
    /// Strip memory block.
    pub strip_memory: bool,
    /// Strip skill index block.
    pub strip_skill_index: bool,
    /// Strip job-result block.
    pub strip_job_results: bool,
    /// Skip bootstrap queries for pending background results.
    pub skip_pending_jobs_bootstrap: bool,
    /// Character budget for rules truncation.
    pub rules_truncation_chars: Option<usize>,
    /// Suffix appended after rules truncation.
    pub rules_truncation_suffix: Option<String>,
}

/// Tool visibility/presentation policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ToolPolicySpec {
    /// Optional policy manifest file.
    pub manifest: Option<String>,
    /// Strict allowlist of tool names.
    pub allowed_tools: Option<Vec<String>>,
    /// Tool names denied by this policy.
    pub denied_tools: Vec<String>,
    /// Whether interactive tools may be exposed.
    pub expose_interactive_tools: Option<bool>,
    /// Whether spawn/wait tools are removed at max depth.
    pub remove_spawn_tools_at_max_depth: Option<bool>,
}

/// Permission inheritance policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct PermissionPolicySpec {
    /// Whether tools may be inherited from the parent registry.
    pub inherit_tools: bool,
    /// Whether filesystem access may exceed the parent process.
    pub allow_filesystem_escalation: bool,
    /// Whether model/provider class may exceed the parent process.
    pub allow_model_escalation: bool,
    /// Whether auth authority may exceed the profile auth profile.
    pub allow_auth_escalation: bool,
}

/// Provider-specific presentation policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ProviderPolicySpec {
    /// Provider prompt/presentation file.
    pub prompt: Option<String>,
    /// Where system prompt content is rendered.
    pub system_prompt_surface: Option<String>,
    /// Whether a tool-clarification message is required.
    pub tool_clarification: Option<bool>,
    /// Whether duplicate system-prompt inclusion is permitted.
    pub allow_duplicate_system_prompt: Option<bool>,
    /// Cache policy id.
    pub cache_policy: Option<String>,
}

/// Provider-independent cache policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct CachePolicySpec {
    /// Foundation cache behavior.
    pub foundation: String,
    /// Profile cache behavior.
    pub profile: String,
    /// Session cache behavior.
    pub session: String,
    /// Turn cache behavior.
    pub turn: String,
    /// None/unsafe cache behavior.
    pub none: String,
}

/// Structured output contract.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct OutputContractSpec {
    /// Contract kind.
    pub kind: String,
    /// Whether valid output is required.
    pub required: bool,
}

/// Audit policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuditPolicySpec {
    /// Whether calls under this policy are audited.
    pub enabled: bool,
    /// Whether provider payloads are retained by hash/blob.
    pub record_provider_payload: bool,
    /// Whether rendered context blocks are retained by hash/blob.
    pub record_context_blocks: bool,
}

/// Settings file refs owned by the profile.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct SettingsSpec {
    /// Managed default settings JSON, relative to the profile directory.
    pub defaults: String,
    /// User profile that stores sparse overrides.
    pub user_overrides_profile: String,
}

/// Auth registry/store refs owned by profiles.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuthSpec {
    /// Readable auth registry under `profiles/`.
    pub registry: String,
    /// Protected raw auth store under `profiles/`.
    pub raw_store: String,
}

/// Readable auth registry stored at `profiles/auth.toml`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuthRegistry {
    /// Schema version.
    pub version: String,
    /// Default credential profile name.
    pub default: String,
    /// Declared credential profiles.
    pub profiles: HashMap<String, AuthProfileSpec>,
}

/// One credential profile entry in [`AuthRegistry`].
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct AuthProfileSpec {
    /// Human-readable description.
    pub description: String,
    /// Backing raw auth store, normally `auth.json`.
    pub store: String,
}

/// Resolved effective execution profile.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedProfile {
    /// Active profile name.
    pub name: String,
    /// Active profile root directory.
    pub active_dir: PathBuf,
    /// Merged profile document.
    pub spec: AgentExecutionSpec,
    /// Merged raw TOML, useful for audit hashes and future settings migration.
    pub raw: Value,
    /// Profiles applied from oldest ancestor to active profile.
    pub profile_chain: Vec<String>,
    /// SHA-256 hash of the resolved raw profile document.
    pub spec_hash: String,
}

impl AgentExecutionSpec {
    /// Prompt ref for a main entrypoint.
    #[must_use]
    pub fn entrypoint_prompt(&self, name: &str) -> Option<&str> {
        self.entrypoints.get(name)?.prompt.as_deref()
    }

    /// Prompt ref for a process.
    #[must_use]
    pub fn process_prompt(&self, name: &str) -> Option<&str> {
        self.processes.get(name)?.prompt.as_deref()
    }

    /// Provider prompt ref.
    #[must_use]
    pub fn provider_prompt(&self, provider: &str) -> Option<&str> {
        self.provider_policies.get(provider)?.prompt.as_deref()
    }

    /// Process spec by id.
    #[must_use]
    pub fn process(&self, name: &str) -> Option<&ProcessSpec> {
        self.processes.get(name)
    }

    /// Context policy by id.
    #[must_use]
    pub fn context_policy(&self, name: &str) -> Option<&ContextPolicySpec> {
        self.context_policies.get(name)
    }

    /// Tool policy by id.
    #[must_use]
    pub fn tool_policy(&self, name: &str) -> Option<&ToolPolicySpec> {
        self.tool_policies.get(name)
    }

    /// Local context policy, if any, matching provider id.
    #[must_use]
    pub fn local_context_policy_for_provider(&self, provider: &str) -> Option<&ContextPolicySpec> {
        self.context_policies.values().find(|policy| {
            policy
                .local_providers
                .iter()
                .any(|candidate| candidate == provider)
        })
    }
}

/// Parse the compiled managed default profile.
#[must_use]
pub fn bundled_default_execution_spec() -> AgentExecutionSpec {
    toml::from_str(include_str!(
        "../../../defaults/profiles/default/profile.toml"
    ))
    .expect("bundled default profile.toml must be a valid AgentExecutionSpec")
}

/// Resolve the active spec, or fall back to compiled managed defaults for
/// diagnostic/repair paths where the on-disk default is temporarily absent.
#[must_use]
pub fn active_execution_spec_or_default() -> AgentExecutionSpec {
    resolve_active_profile()
        .map(|profile| profile.spec)
        .unwrap_or_else(|_| bundled_default_execution_spec())
}

/// Resolve a named process from the active spec, falling back to compiled
/// defaults if recovery is in progress.
#[must_use]
pub fn active_process_spec(name: &str) -> Option<ProcessSpec> {
    active_execution_spec_or_default().process(name).cloned()
}

/// Read the active profile name from `profiles/active.toml`.
#[must_use]
pub fn active_profile_name() -> Option<String> {
    active_profile_name_at(&paths::tron_home())
}

/// Read the active profile name from a specific Tron home.
#[must_use]
pub fn active_profile_name_at(home: &Path) -> Option<String> {
    let content = fs::read_to_string(home.join(dirs::PROFILES).join(files::ACTIVE_TOML)).ok()?;
    parse_active_profile(&content)
}

fn parse_active_profile(content: &str) -> Option<String> {
    let value: Value = toml::from_str(content).ok()?;
    value
        .get("active")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

/// Resolve the active profile or the managed default if no active
/// pointer exists yet.
pub fn resolve_active_profile() -> io::Result<ResolvedProfile> {
    resolve_active_profile_at(&paths::tron_home())
}

/// Resolve the active profile under a specific Tron home.
pub fn resolve_active_profile_at(home: &Path) -> io::Result<ResolvedProfile> {
    let name = active_profile_name_at(home).unwrap_or_else(|| DEFAULT_PROFILE.to_string());
    resolve_profile_at(home, &name)
}

/// Resolve a relative file reference through the active profile inheritance chain.
pub fn resolve_active_file_at(home: &Path, rel: &str) -> io::Result<PathBuf> {
    let name = active_profile_name_at(home).unwrap_or_else(|| DEFAULT_PROFILE.to_string());
    resolve_profile_file_at(home, &name, rel)
}

/// Resolve a relative file reference through one profile's inheritance chain.
pub fn resolve_profile_file_at(home: &Path, name: &str, rel: &str) -> io::Result<PathBuf> {
    for profile in profile_file_candidate_profiles(home, name)? {
        let path = home.join(dirs::PROFILES).join(profile).join(rel);
        if path.is_file() {
            return Ok(path);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("profile `{name}` does not provide file `{rel}`"),
    ))
}

/// Resolve a named profile with inheritance.
pub fn resolve_profile_at(home: &Path, name: &str) -> io::Result<ResolvedProfile> {
    let mut seen = BTreeSet::new();
    let raw = resolve_profile_value(home, name, &mut seen)?;
    let spec: AgentExecutionSpec = raw.clone().try_into().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid profile `{name}`: {error}"),
        )
    })?;
    validate_profile(home, name, &spec)?;
    let profile_chain = profile_file_candidate_profiles(home, name)?
        .into_iter()
        .rev()
        .collect::<Vec<_>>();
    let raw_string = toml::to_string(&raw).unwrap_or_default();
    Ok(ResolvedProfile {
        name: name.to_string(),
        active_dir: home.join(dirs::PROFILES).join(name),
        spec,
        raw,
        profile_chain,
        spec_hash: sha256_hex(raw_string.as_bytes()),
    })
}

fn resolve_profile_value(
    home: &Path,
    name: &str,
    seen: &mut BTreeSet<String>,
) -> io::Result<Value> {
    if !seen.insert(name.to_string()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile inheritance cycle at `{name}`"),
        ));
    }

    let path = home
        .join(dirs::PROFILES)
        .join(name)
        .join(files::PROFILE_TOML);
    let content = fs::read_to_string(&path)?;
    let value: Value = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid TOML in {}: {error}", path.display()),
        )
    })?;

    let inherits = value
        .get("inherits")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let mut merged = Value::Table(Default::default());
    for parent in inherits {
        let parent_value = resolve_profile_value(home, &parent, seen)?;
        deep_merge_toml(&mut merged, parent_value);
    }
    deep_merge_toml(&mut merged, value);
    seen.remove(name);
    Ok(merged)
}

fn deep_merge_toml(base: &mut Value, overlay: Value) {
    match (base, overlay) {
        (Value::Table(base_table), Value::Table(overlay_table)) => {
            for (key, value) in overlay_table {
                match base_table.get_mut(&key) {
                    Some(existing) => deep_merge_toml(existing, value),
                    None => {
                        base_table.insert(key, value);
                    }
                }
            }
        }
        (base_value, overlay_value) => {
            *base_value = overlay_value;
        }
    }
}

fn validate_profile(home: &Path, name: &str, spec: &ProfileSpec) -> io::Result<()> {
    if spec.version != CURRENT_PROFILE_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "profile `{name}` uses schema version `{}`; expected `{CURRENT_PROFILE_VERSION}`",
                spec.version
            ),
        ));
    }
    if spec.auth_profile.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` must select authProfile"),
        ));
    }
    if let Some(profile_class) = spec.profile_class.as_deref() {
        validate_allowed_value(
            name,
            "profileClass",
            profile_class,
            &["base", "normal", "chat", "local", "custom"],
        )?;
    }
    let candidate_profiles = profile_file_candidate_profiles(home, name)?;
    if spec.settings.defaults.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` must define settings.defaults"),
        ));
    }
    validate_profile_file_ref(
        home,
        name,
        &candidate_profiles,
        "settings.defaults",
        &spec.settings.defaults,
    )?;
    validate_profiles_file_ref(home, name, "auth.registry", &spec.auth.registry)?;
    validate_profiles_file_ref(home, name, "auth.rawStore", &spec.auth.raw_store)?;
    validate_auth_profile(home, name, &spec.auth.registry, &spec.auth_profile)?;

    for (entrypoint, entry) in &spec.entrypoints {
        if let Some(prompt) = &entry.prompt {
            validate_profile_file_ref(
                home,
                name,
                &candidate_profiles,
                &format!("entrypoints.{entrypoint}.prompt"),
                prompt,
            )?;
        }
        validate_policy_ref(
            name,
            "modelPolicies",
            &entry.model_policy,
            &spec.model_policies,
        )?;
        validate_policy_ref(
            name,
            "contextPolicies",
            &entry.context_policy,
            &spec.context_policies,
        )?;
        if let Some(local) = &entry.local_context_policy {
            validate_policy_ref(name, "contextPolicies", local, &spec.context_policies)?;
        }
        validate_policy_ref(
            name,
            "toolPolicies",
            &entry.tool_policy,
            &spec.tool_policies,
        )?;
        validate_policy_ref(
            name,
            "permissionPolicies",
            &entry.permission_policy,
            &spec.permission_policies,
        )?;
        validate_policy_ref(
            name,
            "providerPolicies",
            &entry.provider_policy,
            &spec.provider_policies,
        )?;
        validate_policy_ref(
            name,
            "cachePolicies",
            &entry.cache_policy,
            &spec.cache_policies,
        )?;
        validate_policy_ref(name, "auditPolicy", &entry.audit_policy, &spec.audit_policy)?;
    }

    for (process_id, process) in &spec.processes {
        if let Some(prompt) = &process.prompt {
            validate_profile_file_ref(
                home,
                name,
                &candidate_profiles,
                &format!("processes.{process_id}.prompt"),
                prompt,
            )?;
        }
        validate_policy_ref(
            name,
            "modelPolicies",
            &process.model_policy,
            &spec.model_policies,
        )?;
        validate_policy_ref(
            name,
            "contextPolicies",
            &process.context_policy,
            &spec.context_policies,
        )?;
        validate_policy_ref(
            name,
            "toolPolicies",
            &process.tool_policy,
            &spec.tool_policies,
        )?;
        validate_policy_ref(
            name,
            "permissionPolicies",
            &process.permission_policy,
            &spec.permission_policies,
        )?;
        validate_policy_ref(
            name,
            "outputContracts",
            &process.output_contract,
            &spec.output_contracts,
        )?;
        validate_policy_ref(
            name,
            "auditPolicy",
            &process.audit_policy,
            &spec.audit_policy,
        )?;
        validate_tool_overlap(
            name,
            process_id,
            process.allowed_tools.as_deref(),
            &process.denied_tools,
        )?;
    }

    for (policy_id, policy) in &spec.context_policies {
        if let Some(blocks) = &policy.blocks {
            let path = validate_profile_file_ref(
                home,
                name,
                &candidate_profiles,
                &format!("contextPolicies.{policy_id}.blocks"),
                blocks,
            )?;
            validate_context_block_manifest(&path)?;
        }
        if let Some(tool_policy) = &policy.tool_policy {
            validate_policy_ref(name, "toolPolicies", tool_policy, &spec.tool_policies)?;
        }
    }

    for (policy_id, policy) in &spec.tool_policies {
        if let Some(manifest) = &policy.manifest {
            validate_profile_file_ref(
                home,
                name,
                &candidate_profiles,
                &format!("toolPolicies.{policy_id}.manifest"),
                manifest,
            )?;
        }
        validate_tool_overlap(
            name,
            policy_id,
            policy.allowed_tools.as_deref(),
            &policy.denied_tools,
        )?;
    }

    for (provider, policy) in &spec.provider_policies {
        if let Some(prompt) = &policy.prompt {
            validate_profile_file_ref(
                home,
                name,
                &candidate_profiles,
                &format!("providerPolicies.{provider}.prompt"),
                prompt,
            )?;
        }
        if let Some(cache_policy) = &policy.cache_policy {
            validate_policy_ref(name, "cachePolicies", cache_policy, &spec.cache_policies)?;
        }
    }

    Ok(())
}

fn validate_policy_ref<T>(
    profile_name: &str,
    table: &str,
    id: &str,
    policies: &HashMap<String, T>,
) -> io::Result<()> {
    if policies.contains_key(id) {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!("profile `{profile_name}` references missing {table}.{id}"),
    ))
}

fn validate_allowed_value(
    profile_name: &str,
    field: &str,
    value: &str,
    allowed: &[&str],
) -> io::Result<()> {
    if allowed.contains(&value) {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!("profile `{profile_name}` has invalid {field} `{value}`"),
    ))
}

fn validate_tool_overlap(
    profile_name: &str,
    owner: &str,
    allowed: Option<&[String]>,
    denied: &[String],
) -> io::Result<()> {
    let Some(allowed) = allowed else {
        return Ok(());
    };
    if let Some(conflict) = allowed.iter().find(|tool| denied.contains(*tool)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "profile `{profile_name}` policy `{owner}` both allows and denies tool `{conflict}`"
            ),
        ));
    }
    Ok(())
}

fn profile_file_candidate_profiles(home: &Path, name: &str) -> io::Result<Vec<String>> {
    let mut candidates = Vec::new();
    let mut seen = BTreeSet::new();
    collect_profile_file_candidates(home, name, &mut seen, &mut candidates)?;
    if !seen.contains(DEFAULT_PROFILE) {
        candidates.push(DEFAULT_PROFILE.to_string());
    }
    Ok(candidates)
}

fn collect_profile_file_candidates(
    home: &Path,
    name: &str,
    seen: &mut BTreeSet<String>,
    candidates: &mut Vec<String>,
) -> io::Result<()> {
    if !seen.insert(name.to_string()) {
        return Ok(());
    }
    candidates.push(name.to_string());
    let path = home
        .join(dirs::PROFILES)
        .join(name)
        .join(files::PROFILE_TOML);
    let Ok(content) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let value: Value = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid TOML in {}: {error}", path.display()),
        )
    })?;
    let inherits = value
        .get("inherits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    for parent in inherits {
        collect_profile_file_candidates(home, &parent, seen, candidates)?;
    }
    Ok(())
}

fn validate_profile_file_ref(
    home: &Path,
    name: &str,
    candidate_profiles: &[String],
    label: &str,
    rel: &str,
) -> io::Result<PathBuf> {
    validate_relative_ref(name, label, rel)?;
    if candidate_profiles
        .iter()
        .any(|profile| home.join(dirs::PROFILES).join(profile).join(rel).is_file())
    {
        return Ok(candidate_profiles
            .iter()
            .map(|profile| home.join(dirs::PROFILES).join(profile).join(rel))
            .find(|path| path.is_file())
            .expect("is_file checked above"));
    }
    let profile_path = home.join(dirs::PROFILES).join(name).join(rel);
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "profile `{name}` references missing {label} file: {}",
            profile_path.display()
        ),
    ))
}

fn validate_profiles_file_ref(home: &Path, name: &str, label: &str, rel: &str) -> io::Result<()> {
    validate_relative_ref(name, label, rel)?;
    let path = home.join(dirs::PROFILES).join(rel);
    if path.is_file() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "profile `{name}` references missing {label} file: {}",
                path.display()
            ),
        ))
    }
}

fn validate_relative_ref(name: &str, label: &str, rel: &str) -> io::Result<()> {
    let path = Path::new(rel);
    if rel.trim().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` has unsafe {label} file ref `{rel}`"),
        ));
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
struct ContextBlockManifest {
    version: Option<String>,
    blocks: Vec<ContextBlockRef>,
}

impl Default for ContextBlockManifest {
    fn default() -> Self {
        Self {
            version: None,
            blocks: Vec::new(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ContextBlockRef {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    home: Option<String>,
    #[serde(default)]
    cache_class: Option<String>,
    #[serde(default)]
    provider_surface: Option<String>,
}

const KNOWN_CONTEXT_BLOCKS: &[&str] = &[
    "system.prompt",
    "project.rules",
    "memory.root",
    "dynamic.rules",
    "skills.index",
    "skills.activation",
    "skills.active",
    "skills.removal",
    "jobs.results",
    "hooks.addContext",
    "environment.server",
    "environment.workingDirectory",
    "tools.schemas",
    "conversation.messages",
];

fn validate_context_block_manifest(path: &Path) -> io::Result<()> {
    let content = fs::read_to_string(path)?;
    let manifest: ContextBlockManifest = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid context block manifest {}: {error}", path.display()),
        )
    })?;
    let mut seen = BTreeSet::new();
    for block in &manifest.blocks {
        if block.id.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "context block manifest {} has an empty block id",
                    path.display()
                ),
            ));
        }
        if block.name.as_deref().is_some_and(str::is_empty) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "context block manifest {} has an empty name for block `{}`",
                    path.display(),
                    block.id
                ),
            ));
        }
        if let Some(home) = &block.home {
            validate_manifest_enum(
                path,
                &block.id,
                "home",
                home,
                &["profiles", "skills", "memory", "workspace", "internal"],
            )?;
        }
        if let Some(cache_class) = &block.cache_class {
            validate_manifest_enum(
                path,
                &block.id,
                "cacheClass",
                cache_class,
                &["foundation", "profile", "session", "turn", "none"],
            )?;
        }
        if let Some(provider_surface) = &block.provider_surface {
            validate_manifest_enum(
                path,
                &block.id,
                "providerSurface",
                provider_surface,
                &["instructions", "message", "tool", "excluded"],
            )?;
        }
        if !seen.insert(block.id.clone()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "context block manifest {} duplicates block `{}`",
                    path.display(),
                    block.id
                ),
            ));
        }
    }
    for required in KNOWN_CONTEXT_BLOCKS {
        if !seen.contains(*required) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "context block manifest {} is missing required block `{required}`",
                    path.display()
                ),
            ));
        }
    }
    Ok(())
}

fn validate_manifest_enum(
    path: &Path,
    block_id: &str,
    field: &str,
    value: &str,
    allowed: &[&str],
) -> io::Result<()> {
    if allowed.contains(&value) {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "context block manifest {} block `{block_id}` has invalid {field} `{value}`",
            path.display()
        ),
    ))
}

fn validate_auth_profile(
    home: &Path,
    profile_name: &str,
    registry_ref: &str,
    auth_profile: &str,
) -> io::Result<()> {
    validate_relative_ref(profile_name, "auth.registry", registry_ref)?;
    let path = home.join(dirs::PROFILES).join(registry_ref);
    let content = fs::read_to_string(&path)?;
    let registry: AuthRegistry = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid auth registry {}: {error}", path.display()),
        )
    })?;
    for (profile, entry) in &registry.profiles {
        validate_relative_ref(
            profile_name,
            &format!("auth profile `{profile}` store"),
            &entry.store,
        )?;
    }
    if registry.profiles.contains_key(auth_profile) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "auth profile `{auth_profile}` is not declared in {}",
                path.display()
            ),
        ))
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex::encode(digest)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, content: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, content).unwrap();
    }

    fn seed_auth(home: &Path) {
        write(
            &home.join(dirs::PROFILES).join(files::AUTH_TOML),
            r#"
version = "1"
default = "default"

[profiles.default]
store = "auth.json"
"#,
        );
    }

    #[test]
    fn active_profile_reads_toml() {
        assert_eq!(
            parse_active_profile("active = \"user\"\n").as_deref(),
            Some("user")
        );
    }

    #[test]
    fn bundled_default_profile_parses_as_v2_execution_spec() {
        let spec = bundled_default_execution_spec();

        assert_eq!(spec.version, CURRENT_PROFILE_VERSION);
        assert_eq!(spec.name, DEFAULT_PROFILE);
        assert!(spec.managed);
        assert!(spec.entrypoints.contains_key("chat"));
        assert_eq!(spec.processes["compaction"].kind, ProcessKind::Summarizer);
        assert_eq!(spec.processes["memoryRetain"].kind, ProcessKind::Summarizer);
        assert_eq!(
            spec.processes["webFetchSummarizer"].kind,
            ProcessKind::ToolWorker
        );
        assert!(spec.context_policies.contains_key("cloudDefault"));
        assert!(spec.tool_policies.contains_key("localModel"));
        assert!(spec.provider_policies.contains_key("default"));
        assert!(spec.cache_policies.contains_key("default"));
        assert_eq!(spec.settings.defaults, "settings/defaults.json");
    }

    #[test]
    fn managed_session_profiles_resolve_from_seeded_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).unwrap();

        let normal = resolve_profile_at(&home, NORMAL_PROFILE).unwrap();
        let chat = resolve_profile_at(&home, CHAT_PROFILE).unwrap();
        let local = resolve_profile_at(&home, LOCAL_PROFILE).unwrap();

        assert_eq!(normal.spec.profile_class.as_deref(), Some("normal"));
        assert_eq!(chat.spec.profile_class.as_deref(), Some("chat"));
        assert_eq!(local.spec.profile_class.as_deref(), Some("local"));
        assert_eq!(chat.spec.entrypoint_prompt("main"), Some("prompts/chat.md"));
        assert_eq!(
            local.spec.entrypoints["main"].context_policy,
            "localDefault"
        );
        assert_eq!(local.spec.entrypoints["main"].tool_policy, "localModel");
    }

    #[test]
    fn profile_inheritance_deep_merges_tables_and_replaces_arrays() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).unwrap();
        write(
            &home
                .join(dirs::PROFILES)
                .join("child")
                .join(files::PROFILE_TOML),
            r#"
version = "2"
name = "child"
authProfile = "default"
inherits = ["default"]

[entrypoints.chat]
prompt = "prompts/custom-chat.md"
"#,
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("child")
                .join("prompts/custom-chat.md"),
            "chat",
        );

        let resolved = resolve_profile_at(&home, "child").unwrap();

        assert_eq!(
            resolved.spec.entrypoint_prompt("main"),
            Some("prompts/core.md")
        );
        assert_eq!(
            resolved.spec.entrypoint_prompt("chat"),
            Some("prompts/custom-chat.md")
        );
        assert_eq!(
            resolved.spec.entrypoints["chat"].tool_policy, "default",
            "partial child entrypoint override should inherit parent policy fields"
        );
    }

    #[test]
    fn profile_auth_validation_uses_profile_registry_ref() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).unwrap();
        write(
            &home.join(dirs::PROFILES).join("custom-auth.toml"),
            r#"
version = "1"
default = "secondary"

[profiles.secondary]
store = "auth.json"
"#,
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("child")
                .join(files::PROFILE_TOML),
            r#"
version = "2"
name = "child"
authProfile = "secondary"
inherits = ["default"]

[auth]
registry = "custom-auth.toml"
"#,
        );

        let resolved = resolve_profile_at(&home, "child").unwrap();

        assert_eq!(resolved.spec.auth_profile, "secondary");
    }

    #[test]
    fn profile_cycle_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        seed_auth(&home);
        write(
            &home
                .join(dirs::PROFILES)
                .join("a")
                .join(files::PROFILE_TOML),
            r#"version = "2"
name = "a"
authProfile = "default"
inherits = ["b"]
"#,
        );
        write(
            &home
                .join(dirs::PROFILES)
                .join("b")
                .join(files::PROFILE_TOML),
            r#"version = "2"
name = "b"
authProfile = "default"
inherits = ["a"]
"#,
        );

        let error = resolve_profile_at(&home, "a").unwrap_err();
        assert!(error.to_string().contains("cycle"));
    }
}

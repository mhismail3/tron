//! Profile-first execution spec loading.
//!
//! Profiles are the normal control plane for model-facing behavior and harness
//! settings. The managed `default` profile is restorable; user profiles inherit
//! from it and are never silently overwritten.
//!
//! v3 profiles resolve to a typed [`AgentExecutionSpec`]. Runtime modules should
//! consume that effective spec (or helpers backed by it), not hardcoded prompt
//! folders or local/cloud policy constants.
//! Profile file compilation and spec hashing live in `profile/compilation.rs`.
//! Profile validation and context-block manifest contracts live in
//! `profile/validation.rs` so the root stays on typed profile loading.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io;
use std::ops::Deref;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use toml::Value;

use super::paths::{self, dirs, files};
use crate::domains::settings::types::TronSettings;

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
pub const CURRENT_PROFILE_VERSION: &str = "3";

/// Parsed profile document.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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
    /// Provider-facing primitive surface policies (`execute`).
    pub primitive_surface_policies: HashMap<String, PrimitiveSurfacePolicySpec>,
    /// Real worker capability execution policies.
    pub capability_execution_policies: HashMap<String, CapabilityExecutionPolicySpec>,
    /// Capability search policies.
    pub capability_search_policies: HashMap<String, CapabilitySearchPolicySpec>,
    /// Capability context-primer policies.
    pub capability_context_primer_policies: HashMap<String, CapabilityContextPrimerPolicySpec>,
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
    /// Profile-owned effective settings.
    pub settings: TronSettings,
    /// Auth registry/store refs.
    pub auth: AuthSpec,
}

/// Prompt, provider, or context manifest file compiled into the runtime spec.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompiledProfileFile {
    /// Profile-relative reference from TOML.
    pub relative_ref: String,
    /// Absolute source path used for audit/reload.
    pub source_path: PathBuf,
    /// SHA-256 content hash.
    pub hash: String,
    /// Loaded UTF-8 content.
    pub content: String,
}

/// Effective agent execution spec after inheritance, settings overlay, and file loading.
#[derive(Clone, Debug)]
pub struct AgentExecutionSpec {
    /// Merged raw profile document.
    document: ProfileDocument,
    /// Entrypoint prompt files by entrypoint id.
    pub entrypoint_prompts: HashMap<String, CompiledProfileFile>,
    /// Process prompt files by process id.
    pub process_prompts: HashMap<String, CompiledProfileFile>,
    /// Provider prompt files by provider policy id.
    pub provider_prompts: HashMap<String, CompiledProfileFile>,
    /// Context block manifest files by context policy id.
    pub context_manifests: HashMap<String, CompiledProfileFile>,
    /// Readable auth registry used to resolve authProfile.
    pub auth_registry: Option<CompiledProfileFile>,
    /// All source files that affect this compiled spec.
    pub source_files: Vec<PathBuf>,
}

impl Deref for AgentExecutionSpec {
    type Target = ProfileDocument;

    fn deref(&self) -> &Self::Target {
        &self.document
    }
}

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
    /// Provider-facing primitive surface policy id.
    pub primitive_surface_policy: String,
    /// Worker capability execution policy id.
    pub capability_execution_policy: String,
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
    /// Capability-owned worker process.
    CapabilityWorker,
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
    /// Provider-facing primitive surface policy id.
    pub primitive_surface_policy: String,
    /// Worker capability execution policy id.
    pub capability_execution_policy: String,
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
    /// Whether process authority is inherited from the parent registry.
    pub inherit_capabilities: Option<bool>,
    /// Reasoning level string (`none`, `low`, `medium`, `high`, `xhigh`, `max`).
    pub reasoning: Option<String>,
    /// Working directory override.
    pub working_directory: Option<String>,
    /// How process results are injected back into parent context.
    pub result_injection: Option<String>,
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
    /// Provider-facing primitive surface policy to use when this context policy is active.
    pub primitive_surface_policy: Option<String>,
    /// Worker capability execution policy to use when this context policy is active.
    pub capability_execution_policy: Option<String>,
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

/// Provider-facing primitive surface policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct PrimitiveSurfacePolicySpec {
    /// Strict allowlist of model-facing primitive ids.
    pub allowed_primitives: Option<Vec<String>>,
    /// Primitive ids denied by this policy.
    pub denied_primitives: Vec<String>,
    /// Whether interactive capabilities may be exposed.
    pub expose_interactive_capabilities: Option<bool>,
    /// Whether spawn/wait capabilities are removed at max depth.
    pub remove_spawn_at_max_depth: Option<bool>,
}

/// Worker capability execution policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct CapabilityExecutionPolicySpec {
    /// Search policy used by capability::search.
    pub search_policy: Option<String>,
    /// Context primer policy used for generated capability context.
    pub context_primer_policy: Option<String>,
    /// Strict allowlist of contract ids.
    pub allowed_contracts: Option<Vec<String>>,
    /// Contract ids denied by this policy.
    pub denied_contracts: Vec<String>,
    /// Strict allowlist of implementation ids.
    pub allowed_implementations: Option<Vec<String>>,
    /// Implementation ids denied by this policy.
    pub denied_implementations: Vec<String>,
    /// Strict allowlist of plugin ids.
    pub allowed_plugins: Option<Vec<String>>,
    /// Plugin ids denied by this policy.
    pub denied_plugins: Vec<String>,
    /// Optional maximum risk level.
    pub max_risk: Option<String>,
    /// Optional allowlist of effect classes.
    pub allowed_effects: Option<Vec<String>>,
    /// Optional minimum trust tier.
    pub minimum_trust_tier: Option<String>,
}

/// Capability search policy.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct CapabilitySearchPolicySpec {
    /// Whether local lexical search is enabled.
    pub lexical: bool,
    /// Whether local vector search is enabled.
    pub local_vector: bool,
    /// Cloud embeddings are intentionally unsupported for core search.
    pub cloud_embeddings: bool,
    /// Maximum results retained by the index layer.
    pub max_results: usize,
    /// Whether local vector search must be available for this policy.
    pub require_local_vector: bool,
    /// Whether search may fall back to lexical-only when the vector index is degraded.
    pub allow_lexical_only_when_degraded: bool,
}

impl Default for CapabilitySearchPolicySpec {
    fn default() -> Self {
        Self {
            lexical: true,
            local_vector: true,
            cloud_embeddings: false,
            max_results: 50,
            require_local_vector: false,
            allow_lexical_only_when_degraded: true,
        }
    }
}

/// Generated capability context-primer policy.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct CapabilityContextPrimerPolicySpec {
    /// Whether the primer block is rendered.
    pub enabled: bool,
    /// `coreFirstParty` or `allVisibleCompact`.
    pub mode: String,
    /// Approximate token budget.
    pub max_tokens: usize,
    /// Whether examples may be rendered when metadata provides them.
    pub include_examples: bool,
    /// Whether compact payload schema hints may be rendered.
    pub include_compact_schemas: bool,
}

impl Default for CapabilityContextPrimerPolicySpec {
    fn default() -> Self {
        Self {
            enabled: true,
            mode: "coreFirstParty".to_owned(),
            max_tokens: 2600,
            include_examples: true,
            include_compact_schemas: true,
        }
    }
}

/// Permission inheritance policy.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct PermissionPolicySpec {
    /// Whether capabilities may be inherited from the parent registry.
    pub inherit_capabilities: bool,
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
    /// Whether a capability-clarification message is required.
    pub capability_clarification: Option<bool>,
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
#[derive(Clone, Debug)]
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
    fn from_document_uncompiled(document: ProfileDocument) -> Self {
        Self {
            document,
            entrypoint_prompts: HashMap::new(),
            process_prompts: HashMap::new(),
            provider_prompts: HashMap::new(),
            context_manifests: HashMap::new(),
            auth_registry: None,
            source_files: Vec::new(),
        }
    }

    /// Borrow the merged raw profile document.
    #[must_use]
    pub fn document(&self) -> &ProfileDocument {
        &self.document
    }

    /// Borrow the profile-owned effective settings.
    #[must_use]
    pub fn settings(&self) -> &TronSettings {
        &self.document.settings
    }

    /// Prompt ref for a main entrypoint.
    #[must_use]
    pub fn entrypoint_prompt(&self, name: &str) -> Option<&str> {
        self.document.entrypoints.get(name)?.prompt.as_deref()
    }

    /// Prompt ref for a process.
    #[must_use]
    pub fn process_prompt(&self, name: &str) -> Option<&str> {
        self.document.processes.get(name)?.prompt.as_deref()
    }

    /// Provider prompt ref.
    #[must_use]
    pub fn provider_prompt(&self, provider: &str) -> Option<&str> {
        self.document
            .provider_policies
            .get(provider)?
            .prompt
            .as_deref()
    }

    /// Process spec by id.
    #[must_use]
    pub fn process(&self, name: &str) -> Option<&ProcessSpec> {
        self.document.processes.get(name)
    }

    /// Context policy by id.
    #[must_use]
    pub fn context_policy(&self, name: &str) -> Option<&ContextPolicySpec> {
        self.document.context_policies.get(name)
    }

    /// Provider-facing primitive surface policy by id.
    #[must_use]
    pub fn primitive_surface_policy(&self, name: &str) -> Option<&PrimitiveSurfacePolicySpec> {
        self.document.primitive_surface_policies.get(name)
    }

    /// Worker capability execution policy by id.
    #[must_use]
    pub fn capability_execution_policy(
        &self,
        name: &str,
    ) -> Option<&CapabilityExecutionPolicySpec> {
        self.document.capability_execution_policies.get(name)
    }

    /// Capability search policy by id.
    #[must_use]
    pub fn capability_search_policy(&self, name: &str) -> Option<&CapabilitySearchPolicySpec> {
        self.document.capability_search_policies.get(name)
    }

    /// Capability context-primer policy by id.
    #[must_use]
    pub fn capability_context_primer_policy(
        &self,
        name: &str,
    ) -> Option<&CapabilityContextPrimerPolicySpec> {
        self.document.capability_context_primer_policies.get(name)
    }

    /// Context-primer policy by id.
    #[must_use]
    pub fn context_primer_policy(&self, name: &str) -> Option<&CapabilityContextPrimerPolicySpec> {
        self.document.capability_context_primer_policies.get(name)
    }

    /// Local context policy, if any, matching provider id.
    #[must_use]
    pub fn local_context_policy_for_provider(&self, provider: &str) -> Option<&ContextPolicySpec> {
        self.document.context_policies.values().find(|policy| {
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
    let document: ProfileDocument = toml::from_str(include_str!(
        "../../../defaults/profiles/default/profile.toml"
    ))
    .expect("bundled default profile.toml must be a valid ProfileDocument");
    AgentExecutionSpec::from_document_uncompiled(document)
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

/// Resolve the active profile under a specific Tron home.
pub fn resolve_active_profile_at(home: &Path) -> io::Result<ResolvedProfile> {
    let name = active_profile_name_at(home).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "missing active profile pointer: {}",
                home.join(dirs::PROFILES).join(files::ACTIVE_TOML).display()
            ),
        )
    })?;
    resolve_profile_at(home, &name)
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
    resolve_profile_at_with_user_overlay(home, name, true)
}

/// Resolve a named profile without the global user settings overlay.
pub fn resolve_profile_base_at(home: &Path, name: &str) -> io::Result<ResolvedProfile> {
    resolve_profile_at_with_user_overlay(home, name, false)
}

fn resolve_profile_at_with_user_overlay(
    home: &Path,
    name: &str,
    include_user_overlay: bool,
) -> io::Result<ResolvedProfile> {
    let mut seen = BTreeSet::new();
    let mut raw = resolve_profile_value(home, name, &mut seen)?;
    if include_user_overlay {
        apply_user_profile_overlay(home, name, &mut raw)?;
    }
    let document: ProfileDocument = raw.clone().try_into().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid profile `{name}`: {error}"),
        )
    })?;
    validate_profile(home, name, &document)?;
    let candidate_profiles = profile_file_candidate_profiles(home, name)?;
    let spec = compile_agent_execution_spec(home, name, document, &candidate_profiles)?;
    let profile_chain = candidate_profiles.into_iter().rev().collect::<Vec<_>>();
    let raw_string = toml::to_string(&raw).unwrap_or_default();
    let spec_hash = agent_execution_spec_hash(&raw_string, &spec);
    Ok(ResolvedProfile {
        name: name.to_string(),
        active_dir: home.join(dirs::PROFILES).join(name),
        spec,
        raw,
        profile_chain,
        spec_hash,
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

fn apply_user_profile_overlay(home: &Path, active_name: &str, raw: &mut Value) -> io::Result<()> {
    if active_name == USER_PROFILE {
        return Ok(());
    }
    let path = home
        .join(dirs::PROFILES)
        .join(USER_PROFILE)
        .join(files::PROFILE_TOML);
    let Ok(content) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let overlay: Value = toml::from_str(&content).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid TOML in {}: {error}", path.display()),
        )
    })?;
    let Some(settings_overlay) = overlay.get("settings").cloned() else {
        return Ok(());
    };
    let Some(raw_table) = raw.as_table_mut() else {
        return Ok(());
    };
    match raw_table.get_mut("settings") {
        Some(settings) => deep_merge_toml(settings, settings_overlay),
        None => {
            raw_table.insert("settings".to_string(), settings_overlay);
        }
    }
    Ok(())
}

#[path = "profile/compilation.rs"]
mod compilation;
#[path = "profile/validation.rs"]
mod validation;

use compilation::{agent_execution_spec_hash, compile_agent_execution_spec};
pub(crate) use validation::validate_context_block_manifest;
#[cfg(test)]
use validation::{
    CAPABILITY_SCHEMA_PROVIDER_SURFACE, ContextBlockManifest, ContextBlockProviderSurface,
};
use validation::{profile_file_candidate_profiles, validate_profile};

#[cfg(test)]
#[path = "profile/tests.rs"]
mod tests;

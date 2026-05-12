//! Compiled profile runtime service.
//!
//! Profiles are the single runtime control plane for agent behavior and
//! settings. [`ProfileRuntime`] keeps the latest valid compiled profile graph
//! in an atomic snapshot. Reloads are all-or-previous: invalid profile edits
//! are reported and the last known-good spec remains active for in-flight and
//! future sessions.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;
use walkdir::WalkDir;

use crate::domains::settings::types::TronSettings;
use crate::shared::messages::Provider;
use crate::shared::profile::{
    AgentExecutionSpec, AuditPolicySpec, CHAT_PROFILE, CachePolicySpec, CapabilityPolicySpec,
    CompiledProfileFile, ContextPolicySpec, DEFAULT_PROFILE, LOCAL_PROFILE, NORMAL_PROFILE,
    OutputContractSpec, PermissionPolicySpec, ProcessSpec, ProviderPolicySpec, ResolvedProfile,
};

const PROFILE_WATCH_INTERVAL: Duration = Duration::from_secs(2);

/// Current compiled harness snapshot.
#[derive(Clone, Debug)]
pub struct ResolvedHarnessSpec {
    /// Tron home this spec was compiled from.
    pub home: PathBuf,
    /// Resolved active profile.
    pub profile: Arc<ResolvedProfile>,
    /// Effective settings from the compiled profile.
    pub settings: TronSettings,
}

impl ResolvedHarnessSpec {
    /// Active profile name.
    #[must_use]
    pub fn profile_name(&self) -> &str {
        &self.profile.name
    }

    /// Spec hash used by audit records.
    #[must_use]
    pub fn spec_hash(&self) -> &str {
        &self.profile.spec_hash
    }

    /// Compiled execution spec.
    #[must_use]
    pub fn execution_spec(&self) -> &AgentExecutionSpec {
        &self.profile.spec
    }
}

/// Request for primary session planning.
#[derive(Clone, Debug, Default)]
pub struct SessionPlanRequest {
    /// Explicit profile requested by the client.
    pub requested_profile: Option<String>,
    /// Model selected for the session.
    pub model: String,
    /// Session source (`chat`, app-specific source labels, etc.).
    pub source: Option<String>,
    /// Entrypoint id; defaults to `main`.
    pub entrypoint: Option<String>,
}

/// Per-session immutable execution plan.
#[derive(Clone, Debug)]
pub struct SessionExecutionPlan {
    /// Home this plan was compiled from.
    pub home: PathBuf,
    /// Selected profile name.
    pub profile_name: String,
    /// Profile chain from root ancestor to active profile.
    pub profile_chain: Vec<String>,
    /// Resolved profile hash.
    pub spec_hash: String,
    /// Entrypoint id, usually `main`.
    pub entrypoint_id: String,
    /// Requested model.
    pub model: String,
    /// Provider detected from the model, if known.
    pub provider: Option<Provider>,
    /// Resolved auth profile.
    pub auth_profile: String,
    /// Full effective settings snapshot.
    pub settings: TronSettings,
    /// Resolved profile snapshot.
    pub resolved_profile: Arc<ResolvedProfile>,
    /// Entrypoint prompt file, if configured.
    pub prompt: Option<CompiledProfileFile>,
    /// Context policy id.
    pub context_policy_id: String,
    /// Resolved context policy.
    pub context_policy: ContextPolicySpec,
    /// Capability policy id.
    pub capability_policy_id: String,
    /// Resolved capability policy.
    pub capability_policy: CapabilityPolicySpec,
    /// Permission policy id.
    pub permission_policy_id: String,
    /// Resolved permission policy.
    pub permission_policy: PermissionPolicySpec,
    /// Provider policy id.
    pub provider_policy_id: String,
    /// Resolved provider policy.
    pub provider_policy: ProviderPolicySpec,
    /// Cache policy id.
    pub cache_policy_id: String,
    /// Resolved cache policy.
    pub cache_policy: CachePolicySpec,
    /// Audit policy id.
    pub audit_policy_id: String,
    /// Resolved audit policy.
    pub audit_policy: AuditPolicySpec,
}

impl SessionExecutionPlan {
    /// Runtime context view derived from this immutable session plan.
    #[must_use]
    pub fn runtime_context_policy(
        &self,
    ) -> crate::domains::agent::runner::context::local_policy::ContextPolicy {
        let provider_is_local = self.provider.is_some_and(|provider| {
            crate::domains::agent::runner::context::local_policy::provider_is_local_for_spec(
                provider,
                &self.resolved_profile.spec,
            )
        });
        crate::domains::agent::runner::context::local_policy::ContextPolicy::from_resolved_parts(
            self.context_policy_id.clone(),
            self.context_policy.clone(),
            Some(self.capability_policy.clone()),
            provider_is_local || !self.context_policy.local_providers.is_empty(),
        )
    }
}

/// Per-process immutable execution plan.
#[derive(Clone, Debug)]
pub struct ProcessExecutionPlan {
    /// Process id.
    pub process_id: String,
    /// Resolved process spec.
    pub process: ProcessSpec,
    /// Process prompt file, if configured.
    pub prompt: Option<CompiledProfileFile>,
    /// Model policy id.
    pub model_policy_id: String,
    /// Context policy id.
    pub context_policy_id: String,
    /// Resolved context policy.
    pub context_policy: ContextPolicySpec,
    /// Capability policy id.
    pub capability_policy_id: String,
    /// Resolved capability policy.
    pub capability_policy: CapabilityPolicySpec,
    /// Permission policy id.
    pub permission_policy_id: String,
    /// Resolved permission policy.
    pub permission_policy: PermissionPolicySpec,
    /// Output contract id.
    pub output_contract_id: String,
    /// Resolved output contract.
    pub output_contract: OutputContractSpec,
    /// Audit policy id.
    pub audit_policy_id: String,
    /// Resolved audit policy.
    pub audit_policy: AuditPolicySpec,
    /// Parent profile snapshot used to plan the process.
    pub resolved_profile: Arc<ResolvedProfile>,
}

impl ProcessExecutionPlan {
    /// Runtime context view derived from this immutable process plan.
    #[must_use]
    pub fn runtime_context_policy(
        &self,
    ) -> crate::domains::agent::runner::context::local_policy::ContextPolicy {
        crate::domains::agent::runner::context::local_policy::ContextPolicy::from_resolved_parts(
            self.context_policy_id.clone(),
            self.context_policy.clone(),
            Some(self.capability_policy.clone()),
            !self.context_policy.local_providers.is_empty(),
        )
    }
}

/// Atomic owner for the current compiled profile runtime.
pub struct ProfileRuntime {
    home: PathBuf,
    current: ArcSwap<ResolvedHarnessSpec>,
}

impl ProfileRuntime {
    /// Load and validate the active profile runtime from a Tron home.
    pub fn load(home: impl AsRef<Path>) -> std::io::Result<Self> {
        let home = home.as_ref().to_path_buf();
        let current = Arc::new(load_harness_spec(&home)?);
        Ok(Self {
            home,
            current: ArcSwap::from(current),
        })
    }

    /// Tron home backing this runtime.
    #[must_use]
    pub fn home(&self) -> &Path {
        &self.home
    }

    /// Current valid compiled spec. Running sessions should keep this Arc as
    /// their snapshot.
    #[must_use]
    pub fn current(&self) -> Arc<ResolvedHarnessSpec> {
        self.current.load_full()
    }

    /// Resolve a profile without swapping the active runtime.
    pub fn resolve_profile(&self, name: &str) -> std::io::Result<Arc<ResolvedProfile>> {
        crate::shared::profile::resolve_profile_at(&self.home, name).map(Arc::new)
    }

    /// Recompile the active profile and swap it in only if validation succeeds.
    pub fn reload_now(&self, reason: &str) -> std::io::Result<Arc<ResolvedHarnessSpec>> {
        match load_harness_spec(&self.home) {
            Ok(next) => {
                let next = Arc::new(next);
                self.current.store(next.clone());
                crate::domains::settings::init_settings(next.settings.clone());
                tracing::info!(
                    reason,
                    profile = next.profile_name(),
                    spec_hash = next.spec_hash(),
                    "profile runtime reloaded"
                );
                Ok(next)
            }
            Err(error) => {
                tracing::warn!(
                    reason,
                    error = %error,
                    "profile runtime reload rejected; keeping previous valid spec"
                );
                Err(error)
            }
        }
    }

    /// Spawn a lightweight profile watcher.
    ///
    /// The watcher hashes the canonical profile control plane (`.toml` and
    /// prompt/policy `.md` files under `profiles/`) and reloads through the
    /// same strict compiler used at startup. Invalid edits are rejected and the
    /// last valid snapshot remains active.
    #[must_use]
    pub fn spawn_watcher(
        self: Arc<Self>,
        cancel: CancellationToken,
    ) -> tokio::task::JoinHandle<()> {
        self.spawn_watcher_with_interval(cancel, PROFILE_WATCH_INTERVAL)
    }

    #[must_use]
    fn spawn_watcher_with_interval(
        self: Arc<Self>,
        cancel: CancellationToken,
        interval: Duration,
    ) -> tokio::task::JoinHandle<()> {
        let initial_hash = match profile_tree_hash(&self.home) {
            Ok(hash) => Some(hash),
            Err(error) => {
                tracing::warn!(error = %error, "profile watcher could not hash initial profile tree");
                None
            }
        };
        tokio::spawn(async move {
            self.watch_profiles(cancel, interval, initial_hash).await;
        })
    }

    async fn watch_profiles(
        self: Arc<Self>,
        cancel: CancellationToken,
        interval: Duration,
        mut last_hash: Option<String>,
    ) {
        let mut ticker = tokio::time::interval(interval);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                () = cancel.cancelled() => break,
                _ = ticker.tick() => {
                    let next_hash = match profile_tree_hash(&self.home) {
                        Ok(hash) => hash,
                        Err(error) => {
                            tracing::warn!(error = %error, "profile watcher scan failed");
                            continue;
                        }
                    };
                    if last_hash.as_deref() == Some(next_hash.as_str()) {
                        continue;
                    }
                    last_hash = Some(next_hash);
                    if let Err(error) = self.reload_now("profile watcher") {
                        tracing::warn!(
                            error = %error,
                            "profile watcher observed an invalid edit; previous profile runtime remains active"
                        );
                    }
                }
            }
        }
    }

    /// Plan a primary session from the current snapshot.
    pub fn plan_session(
        &self,
        request: SessionPlanRequest,
    ) -> std::io::Result<SessionExecutionPlan> {
        let provider =
            crate::domains::model::providers::models::registry::detect_provider_from_model(
                &request.model,
            );
        let current = self.current();
        let local_model = provider.is_some_and(|provider| {
            crate::domains::agent::runner::context::local_policy::provider_is_local_for_spec(
                provider,
                current.execution_spec(),
            )
        });
        let mut profile_name = request
            .requested_profile
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| {
                if local_model {
                    LOCAL_PROFILE.to_string()
                } else if request.source.as_deref() == Some("chat") {
                    CHAT_PROFILE.to_string()
                } else {
                    NORMAL_PROFILE.to_string()
                }
            });

        if profile_name == DEFAULT_PROFILE {
            profile_name = NORMAL_PROFILE.to_string();
        }

        let mut resolved = self.resolve_profile(&profile_name)?;
        if local_model && resolved.spec.profile_class.as_deref() != Some(LOCAL_PROFILE) {
            profile_name = LOCAL_PROFILE.to_string();
            resolved = self.resolve_profile(&profile_name)?;
        }

        build_session_plan(
            &self.home,
            resolved,
            request.entrypoint.as_deref().unwrap_or("main"),
            request.model,
            provider,
        )
    }

    /// Plan a process from a parent/session profile snapshot.
    pub fn plan_process(
        &self,
        process_id: &str,
        parent: Option<&SessionExecutionPlan>,
    ) -> std::io::Result<ProcessExecutionPlan> {
        let resolved = parent
            .map(|plan| plan.resolved_profile.clone())
            .unwrap_or_else(|| self.current().profile.clone());
        build_process_plan(resolved, process_id)
    }
}

fn profile_tree_hash(home: &Path) -> std::io::Result<String> {
    let profiles_dir = home.join(crate::shared::paths::dirs::PROFILES);
    let mut files = Vec::new();
    if !profiles_dir.exists() {
        return Ok(String::new());
    }
    for entry in WalkDir::new(&profiles_dir).follow_links(false) {
        let entry = entry.map_err(std::io::Error::other)?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if path.file_name().and_then(|name| name.to_str())
            == Some(crate::shared::paths::files::AUTH_JSON)
        {
            continue;
        }
        let Some(extension) = path.extension().and_then(|extension| extension.to_str()) else {
            continue;
        };
        if !matches!(extension, "toml" | "md") {
            continue;
        }
        files.push(path.to_path_buf());
    }
    files.sort();

    let mut hasher = Sha256::new();
    for path in files {
        let relative = path.strip_prefix(&profiles_dir).unwrap_or(&path);
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(std::fs::read(&path)?);
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn load_harness_spec(home: &Path) -> std::io::Result<ResolvedHarnessSpec> {
    let profile = Arc::new(crate::shared::profile::resolve_active_profile_at(home)?);
    let settings = effective_settings(profile.spec.settings())?;
    Ok(ResolvedHarnessSpec {
        home: home.to_path_buf(),
        profile,
        settings,
    })
}

fn build_session_plan(
    home: &Path,
    resolved_profile: Arc<ResolvedProfile>,
    entrypoint_id: &str,
    model: String,
    provider: Option<Provider>,
) -> std::io::Result<SessionExecutionPlan> {
    let spec = &resolved_profile.spec;
    let entrypoint = spec.entrypoints.get(entrypoint_id).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "profile `{}` is missing entrypoint `{entrypoint_id}`",
                resolved_profile.name
            ),
        )
    })?;
    let context_policy_id = if provider.is_some_and(|provider| {
        crate::domains::agent::runner::context::local_policy::provider_is_local_for_spec(
            provider, spec,
        )
    }) {
        entrypoint
            .local_context_policy
            .as_deref()
            .unwrap_or(&entrypoint.context_policy)
            .to_string()
    } else {
        entrypoint.context_policy.clone()
    };
    let capability_policy_id = spec
        .context_policy(&context_policy_id)
        .and_then(|policy| policy.capability_policy.clone())
        .unwrap_or_else(|| entrypoint.capability_policy.clone());
    let context_policy = required_spec_ref(
        &resolved_profile.name,
        "context policy",
        &context_policy_id,
        spec.context_policy(&context_policy_id).cloned(),
    )?;
    let capability_policy = required_spec_ref(
        &resolved_profile.name,
        "capability policy",
        &capability_policy_id,
        spec.capability_policy(&capability_policy_id).cloned(),
    )?;
    let permission_policy = required_spec_ref(
        &resolved_profile.name,
        "permission policy",
        &entrypoint.permission_policy,
        spec.permission_policies
            .get(&entrypoint.permission_policy)
            .cloned(),
    )?;
    let provider_policy = required_spec_ref(
        &resolved_profile.name,
        "provider policy",
        &entrypoint.provider_policy,
        spec.provider_policies
            .get(&entrypoint.provider_policy)
            .cloned(),
    )?;
    let cache_policy = required_spec_ref(
        &resolved_profile.name,
        "cache policy",
        &entrypoint.cache_policy,
        spec.cache_policies.get(&entrypoint.cache_policy).cloned(),
    )?;
    let audit_policy = required_spec_ref(
        &resolved_profile.name,
        "audit policy",
        &entrypoint.audit_policy,
        spec.audit_policy.get(&entrypoint.audit_policy).cloned(),
    )?;

    Ok(SessionExecutionPlan {
        home: home.to_path_buf(),
        profile_name: resolved_profile.name.clone(),
        profile_chain: resolved_profile.profile_chain.clone(),
        spec_hash: resolved_profile.spec_hash.clone(),
        entrypoint_id: entrypoint_id.to_string(),
        model,
        provider,
        auth_profile: spec.auth_profile.clone(),
        settings: effective_settings(spec.settings())?,
        prompt: spec.entrypoint_prompts.get(entrypoint_id).cloned(),
        context_policy,
        context_policy_id,
        capability_policy,
        capability_policy_id,
        permission_policy,
        permission_policy_id: entrypoint.permission_policy.clone(),
        provider_policy,
        provider_policy_id: entrypoint.provider_policy.clone(),
        cache_policy,
        cache_policy_id: entrypoint.cache_policy.clone(),
        audit_policy,
        audit_policy_id: entrypoint.audit_policy.clone(),
        resolved_profile,
    })
}

fn required_spec_ref<T>(
    profile_name: &str,
    kind: &str,
    id: &str,
    value: Option<T>,
) -> std::io::Result<T> {
    value.ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("profile `{profile_name}` references missing {kind} `{id}`"),
        )
    })
}

fn effective_settings(settings: &TronSettings) -> std::io::Result<TronSettings> {
    let mut settings = settings.clone();
    crate::domains::settings::loader::apply_env_overrides(&mut settings);
    settings.validate();
    settings.validate_strict().map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("profile settings are invalid after environment overrides: {error}"),
        )
    })?;
    Ok(settings)
}

fn build_process_plan(
    resolved_profile: Arc<ResolvedProfile>,
    process_id: &str,
) -> std::io::Result<ProcessExecutionPlan> {
    let spec = &resolved_profile.spec;
    let process = spec.process(process_id).cloned().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "profile `{}` is missing process `{process_id}`",
                resolved_profile.name
            ),
        )
    })?;
    let context_policy = required_spec_ref(
        &resolved_profile.name,
        "context policy",
        &process.context_policy,
        spec.context_policy(&process.context_policy).cloned(),
    )?;
    let capability_policy = required_spec_ref(
        &resolved_profile.name,
        "capability policy",
        &process.capability_policy,
        spec.capability_policy(&process.capability_policy).cloned(),
    )?;
    let permission_policy = required_spec_ref(
        &resolved_profile.name,
        "permission policy",
        &process.permission_policy,
        spec.permission_policies
            .get(&process.permission_policy)
            .cloned(),
    )?;
    let output_contract = required_spec_ref(
        &resolved_profile.name,
        "output contract",
        &process.output_contract,
        spec.output_contracts.get(&process.output_contract).cloned(),
    )?;
    let audit_policy = required_spec_ref(
        &resolved_profile.name,
        "audit policy",
        &process.audit_policy,
        spec.audit_policy.get(&process.audit_policy).cloned(),
    )?;

    Ok(ProcessExecutionPlan {
        process_id: process_id.to_string(),
        prompt: spec.process_prompts.get(process_id).cloned(),
        model_policy_id: process.model_policy.clone(),
        context_policy,
        context_policy_id: process.context_policy.clone(),
        capability_policy,
        capability_policy_id: process.capability_policy.clone(),
        permission_policy,
        permission_policy_id: process.permission_policy.clone(),
        output_contract,
        output_contract_id: process.output_contract.clone(),
        audit_policy,
        audit_policy_id: process.audit_policy.clone(),
        process,
        resolved_profile,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded_runtime() -> (tempfile::TempDir, ProfileRuntime) {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        let runtime = ProfileRuntime::load(&home).unwrap();
        (dir, runtime)
    }

    #[test]
    fn current_returns_compiled_active_profile() {
        let (_dir, runtime) = seeded_runtime();
        let current = runtime.current();

        assert_eq!(current.profile_name(), NORMAL_PROFILE);
        assert_eq!(current.settings.server.default_provider, "anthropic");
        assert!(
            current
                .execution_spec()
                .entrypoint_prompts
                .contains_key("main")
        );
    }

    #[test]
    fn invalid_reload_keeps_previous_spec() {
        let (_dir, runtime) = seeded_runtime();
        let before = runtime.current();
        let profile_path = runtime
            .home()
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        std::fs::write(&profile_path, "{broken").unwrap();

        let error = runtime.reload_now("test").unwrap_err();
        let after = runtime.current();

        assert!(error.to_string().contains("invalid TOML"));
        assert!(Arc::ptr_eq(&before, &after));
    }

    #[test]
    fn reload_updates_global_settings_snapshot() {
        let _settings_guard = crate::domains::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::reset_settings();
        let (_dir, runtime) = seeded_runtime();
        crate::domains::settings::init_settings(runtime.current().settings.clone());
        let profile_path = runtime
            .home()
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        let mut profile = std::fs::read_to_string(&profile_path).unwrap();
        profile.push_str("\n[settings.server]\ndefaultModel = \"reload-test-model\"\n");
        std::fs::write(&profile_path, profile).unwrap();

        runtime.reload_now("test").unwrap();

        assert_eq!(
            crate::domains::settings::get_settings()
                .server
                .default_model,
            "reload-test-model"
        );
        crate::domains::settings::reset_settings();
    }

    #[tokio::test]
    async fn watcher_reloads_valid_profile_edits() {
        let _settings_guard = crate::domains::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        let runtime = Arc::new(ProfileRuntime::load(&home).unwrap());
        crate::domains::settings::init_settings(runtime.current().settings.clone());
        let cancel = CancellationToken::new();
        let handle = runtime
            .clone()
            .spawn_watcher_with_interval(cancel.clone(), Duration::from_millis(20));

        let profile_path = home
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        let mut profile = std::fs::read_to_string(&profile_path).unwrap();
        profile.push_str("\n[settings.server]\ndefaultModel = \"watcher-test-model\"\n");
        std::fs::write(&profile_path, profile).unwrap();

        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if runtime.current().settings.server.default_model == "watcher-test-model"
                    && crate::domains::settings::get_settings()
                        .server
                        .default_model
                        == "watcher-test-model"
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("watcher should reload a valid profile edit");

        cancel.cancel();
        handle.await.unwrap();
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn local_model_plans_local_profile() {
        let (_dir, runtime) = seeded_runtime();

        let plan = runtime
            .plan_session(SessionPlanRequest {
                requested_profile: Some(NORMAL_PROFILE.to_string()),
                model: "ollama/gemma4:e4b".to_string(),
                source: None,
                entrypoint: None,
            })
            .unwrap();

        assert_eq!(plan.profile_name, LOCAL_PROFILE);
        assert_eq!(plan.context_policy_id, "localDefault");
        assert_eq!(plan.capability_policy_id, "localModel");
    }

    #[test]
    fn process_plan_resolves_prompt_and_policies() {
        let (_dir, runtime) = seeded_runtime();

        let plan = runtime.plan_process("compaction", None).unwrap();

        assert_eq!(plan.process_id, "compaction");
        assert!(plan.prompt.is_some());
        assert_eq!(plan.capability_policy_id, "none");
        assert_eq!(plan.output_contract_id, "compactionSummary");
    }
}

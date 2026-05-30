//! Profile document and context-block manifest validation.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use toml::Value;

use super::super::paths::{dirs, files};
use super::{AuthRegistry, CURRENT_PROFILE_VERSION, DEFAULT_PROFILE, ProfileDocument};

pub(super) fn validate_profile(home: &Path, name: &str, spec: &ProfileDocument) -> io::Result<()> {
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
    let mut settings = spec.settings.clone();
    settings.validate_strict().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` has invalid settings: {error}"),
        )
    })?;
    settings.validate();
    settings.validate_strict().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` has invalid settings: {error}"),
        )
    })?;
    let _ = validate_profiles_file_ref(home, name, "auth.registry", &spec.auth.registry)?;
    let _ = validate_profiles_file_ref(home, name, "auth.rawStore", &spec.auth.raw_store)?;
    validate_auth_profile(home, name, &spec.auth.registry, &spec.auth_profile)?;
    if !spec.entrypoints.contains_key("main") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("profile `{name}` must define entrypoints.main"),
        ));
    }

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
            "primitiveSurfacePolicies",
            &entry.primitive_surface_policy,
            &spec.primitive_surface_policies,
        )?;
        validate_policy_ref(
            name,
            "capabilityExecutionPolicies",
            &entry.capability_execution_policy,
            &spec.capability_execution_policies,
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
            "primitiveSurfacePolicies",
            &process.primitive_surface_policy,
            &spec.primitive_surface_policies,
        )?;
        validate_policy_ref(
            name,
            "capabilityExecutionPolicies",
            &process.capability_execution_policy,
            &spec.capability_execution_policies,
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
        if let Some(primitive_surface_policy) = &policy.primitive_surface_policy {
            validate_policy_ref(
                name,
                "primitiveSurfacePolicies",
                primitive_surface_policy,
                &spec.primitive_surface_policies,
            )?;
        }
        if let Some(capability_execution_policy) = &policy.capability_execution_policy {
            validate_policy_ref(
                name,
                "capabilityExecutionPolicies",
                capability_execution_policy,
                &spec.capability_execution_policies,
            )?;
        }
    }

    for (policy_id, policy) in &spec.primitive_surface_policies {
        validate_primitive_overlap(
            name,
            policy_id,
            policy.allowed_primitives.as_deref(),
            &policy.denied_primitives,
        )?;
    }

    for (policy_id, policy) in &spec.capability_execution_policies {
        if let Some(search_policy) = &policy.search_policy {
            validate_policy_ref(
                name,
                "capabilitySearchPolicies",
                search_policy,
                &spec.capability_search_policies,
            )?;
        }
        if let Some(context_primer_policy) = &policy.context_primer_policy {
            validate_policy_ref(
                name,
                "capabilityContextPrimerPolicies",
                context_primer_policy,
                &spec.capability_context_primer_policies,
            )?;
        }
        validate_policy_overlap(
            name,
            policy_id,
            "contract",
            policy.allowed_contracts.as_deref(),
            &policy.denied_contracts,
        )?;
        validate_policy_overlap(
            name,
            policy_id,
            "implementation",
            policy.allowed_implementations.as_deref(),
            &policy.denied_implementations,
        )?;
        validate_policy_overlap(
            name,
            policy_id,
            "plugin",
            policy.allowed_plugins.as_deref(),
            &policy.denied_plugins,
        )?;
    }

    for (policy_id, policy) in &spec.capability_search_policies {
        if !policy.lexical && !policy.local_vector {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{name}` capabilitySearchPolicies.{policy_id} disables both lexical and localVector search"
                ),
            ));
        }
        if policy.cloud_embeddings {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{name}` capabilitySearchPolicies.{policy_id}.cloudEmbeddings must remain false"
                ),
            ));
        }
        if policy.max_results == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{name}` capabilitySearchPolicies.{policy_id}.maxResults must be positive"
                ),
            ));
        }
        if policy.require_local_vector && !policy.local_vector {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{name}` capabilitySearchPolicies.{policy_id}.requireLocalVector requires localVector"
                ),
            ));
        }
        if policy.require_local_vector && policy.allow_lexical_only_when_degraded {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{name}` capabilitySearchPolicies.{policy_id} cannot both require localVector and allow lexical-only degraded search"
                ),
            ));
        }
    }

    for (policy_id, policy) in &spec.capability_context_primer_policies {
        if !matches!(policy.mode.as_str(), "coreFirstParty" | "allVisibleCompact") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{name}` capabilityContextPrimerPolicies.{policy_id}.mode must be coreFirstParty or allVisibleCompact"
                ),
            ));
        }
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

fn validate_policy_overlap(
    profile_name: &str,
    owner: &str,
    subject: &str,
    allowed: Option<&[String]>,
    denied: &[String],
) -> io::Result<()> {
    let Some(allowed) = allowed else {
        return Ok(());
    };
    if let Some(conflict) = allowed
        .iter()
        .find(|capability| denied.contains(*capability))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "profile `{profile_name}` policy `{owner}` both allows and denies {subject} `{conflict}`"
            ),
        ));
    }
    Ok(())
}

fn validate_primitive_overlap(
    profile_name: &str,
    owner: &str,
    allowed: Option<&[String]>,
    denied: &[String],
) -> io::Result<()> {
    const PRIMITIVES: &[&str] = &["execute"];
    for primitive in allowed.into_iter().flatten().chain(denied.iter()) {
        if !PRIMITIVES.contains(&primitive.as_str()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "profile `{profile_name}` primitiveSurfacePolicies.{owner} references non-primitive `{primitive}`; use capabilityExecutionPolicies for contracts and implementations"
                ),
            ));
        }
    }
    validate_policy_overlap(profile_name, owner, "primitive", allowed, denied)
}

pub(super) fn profile_file_candidate_profiles(home: &Path, name: &str) -> io::Result<Vec<String>> {
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

pub(super) fn validate_profile_file_ref(
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

pub(super) fn validate_profiles_file_ref(
    home: &Path,
    name: &str,
    label: &str,
    rel: &str,
) -> io::Result<PathBuf> {
    validate_relative_ref(name, label, rel)?;
    let path = home.join(dirs::PROFILES).join(rel);
    if path.is_file() {
        Ok(path)
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum ContextBlockProviderSurface {
    Instructions,
    Message,
    #[serde(rename = "capability")]
    Capability,
    Excluded,
}

impl ContextBlockProviderSurface {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Instructions => "instructions",
            Self::Message => "message",
            Self::Capability => CAPABILITY_SCHEMA_PROVIDER_SURFACE,
            Self::Excluded => "excluded",
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(super) struct ContextBlockManifest {
    version: Option<String>,
    pub(super) blocks: Vec<ContextBlockRef>,
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
pub(super) struct ContextBlockRef {
    pub(super) id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    home: Option<String>,
    #[serde(default)]
    cache_class: Option<String>,
    #[serde(default)]
    pub(super) provider_surface: Option<ContextBlockProviderSurface>,
}

const KNOWN_CONTEXT_BLOCKS: &[&str] = &[
    "system.prompt",
    "project.rules",
    "memory.root",
    "dynamic.rules",
    "capabilities.primer",
    "skills.index",
    "skills.activation",
    "skills.active",
    "skills.removal",
    "jobs.results",
    "hooks.addContext",
    "environment.server",
    "environment.workingDirectory",
    "capabilities.schemas",
    "conversation.messages",
];

pub(crate) const CAPABILITY_SCHEMA_PROVIDER_SURFACE: &str = "capability";

pub(crate) fn validate_context_block_manifest(path: &Path) -> io::Result<()> {
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
        let _ = block
            .provider_surface
            .map(ContextBlockProviderSurface::as_str);
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

pub(super) fn validate_auth_profile(
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

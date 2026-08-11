use std::collections::BTreeMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::compiler::{CompileError, CompiledSource, SourceKind, compile_typescript};
#[cfg(test)]
use super::evaluator::{Broker, EvaluationError, evaluate_skill};
use super::process_evaluator::{
    AsyncBroker, CodeHelper, ProcessEvaluationError, invoke_skill_in_helper,
};
use super::types::RuntimeLimits;
use tokio_util::sync::CancellationToken;

const MAX_SKILLS: usize = 256;
const MAX_SKILL_PAGE_SIZE: usize = 32;
const MAX_MANIFEST_BYTES: usize = 64 * 1024;
const MAX_MODULE_BYTES: usize = 256 * 1024;

/// Source precedence for an agent-authored skill.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillOrigin {
    /// Engine profile skill available across projects.
    Profile,
    /// Explicitly trusted project-local skill, which shadows the same profile id.
    Project,
}

/// Bounded metadata from one `SKILL.md` package.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillDescriptor {
    /// Stable package id.
    pub id: String,
    /// Human-readable title.
    pub name: String,
    /// Short discovery description.
    pub summary: String,
    /// Instruction body supplied only after the skill is selected.
    pub instructions: String,
    /// Discovery source.
    pub origin: SkillOrigin,
}

/// Bounded progressive-disclosure row which never includes instructions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillSummary {
    /// Stable package id.
    pub id: String,
    /// Human-readable title.
    pub name: String,
    /// Short discovery description.
    pub summary: String,
    /// Discovery source.
    pub origin: SkillOrigin,
}

/// One bounded stable-id page.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillPage {
    /// At most 32 summaries.
    pub skills: Vec<SkillSummary>,
    /// Last returned id, accepted as the next exclusive cursor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

/// One validated single-file callable module pinned to exact bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedSkillModule {
    /// Owning skill.
    pub skill: SkillDescriptor,
    /// Package-relative module path.
    pub module: String,
    /// Exact original source digest.
    pub source_digest: String,
    /// Exact emitted JavaScript digest.
    pub compiled_digest: String,
    /// Type-stripped ES module. It has one default export and no imports.
    pub javascript: String,
    /// Engine-derived isolated state namespace. Physical paths are never
    /// exposed to the helper or module.
    state_namespace: String,
}

/// Result of directly invoking a skill module in the broker-only runtime.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkillInvocationResult {
    /// JSON-safe module return value.
    pub value: serde_json::Value,
    /// Bounded console output.
    pub output: Vec<String>,
}

impl ResolvedSkillModule {
    /// Invoke the digest-pinned module only in the disposable helper process.
    pub async fn invoke_in_helper(
        &self,
        helper: &CodeHelper,
        invocation_key: &str,
        input: &serde_json::Value,
        broker: Arc<dyn AsyncBroker>,
        limits: &RuntimeLimits,
        cancellation: &CancellationToken,
    ) -> Result<SkillInvocationResult, SkillError> {
        validate_invocation_key(invocation_key)?;
        let module_name = format!("skill-{}.mjs", self.compiled_digest);
        let state_namespace = self.state_namespace();
        let outcome = invoke_skill_in_helper(
            helper,
            &module_name,
            &self.javascript,
            &self.source_digest,
            &state_namespace,
            invocation_key,
            input,
            broker,
            limits,
            cancellation,
        )
        .await?;
        Ok(SkillInvocationResult {
            value: outcome.value,
            output: outcome.output,
        })
    }

    /// Invoke the digest-pinned default export without starting a subagent.
    ///
    /// Nested broker call ids are derived from the module digest, outer
    /// invocation key, and ordinal, so broker implementations can recover an
    /// interrupted call idempotently.
    #[cfg(test)]
    pub fn invoke(
        &self,
        invocation_key: &str,
        input: &serde_json::Value,
        broker: Arc<dyn Broker>,
        limits: &RuntimeLimits,
    ) -> Result<SkillInvocationResult, SkillError> {
        validate_invocation_key(invocation_key)?;
        let module_name = format!("skill-{}.mjs", self.compiled_digest);
        let state_namespace = self.state_namespace();
        let outcome = evaluate_skill(
            &module_name,
            &self.javascript,
            &self.source_digest,
            &state_namespace,
            invocation_key,
            input,
            broker,
            limits,
        )?;
        Ok(SkillInvocationResult {
            value: outcome.value,
            output: outcome.output,
        })
    }

    pub(crate) fn state_namespace(&self) -> String {
        self.state_namespace.clone()
    }
}

/// Skill discovery/resolution failure.
#[derive(Debug, Error)]
pub enum SkillError {
    #[error("skill filesystem access failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid skill package: {0}")]
    Invalid(String),
    #[error("unknown skill '{0}'")]
    NotFound(String),
    #[error(transparent)]
    Compile(#[from] CompileError),
    #[error("skill execution failed: {0}")]
    Runtime(String),
}

#[cfg(test)]
impl From<EvaluationError> for SkillError {
    fn from(error: EvaluationError) -> Self {
        Self::Runtime(error.to_string())
    }
}

impl From<ProcessEvaluationError> for SkillError {
    fn from(error: ProcessEvaluationError) -> Self {
        Self::Runtime(error.to_string())
    }
}

fn validate_invocation_key(invocation_key: &str) -> Result<(), SkillError> {
    if invocation_key.trim().is_empty() || invocation_key.len() > 200 {
        return Err(SkillError::Invalid(
            "skill invocation key must contain 1..=200 bytes".to_owned(),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct FoundSkill {
    descriptor: SkillDescriptor,
    root: PathBuf,
    state_namespace: String,
}

/// Deterministic profile/project skill catalog.
///
/// Discovery never creates packages and never imports legacy workers. A clean
/// profile therefore starts with an empty catalog. Project packages are
/// ignored until the caller supplies a root and explicitly marks it trusted.
#[derive(Debug, Clone)]
pub struct SkillCatalog {
    profile_root: PathBuf,
    project_root: Option<PathBuf>,
    trust_project: bool,
    project_namespace: Option<String>,
}

impl SkillCatalog {
    /// Create a catalog over explicit `skills/` roots.
    #[must_use]
    pub fn new(
        profile_root: impl Into<PathBuf>,
        project_root: Option<PathBuf>,
        trust_project: bool,
    ) -> Self {
        let project_namespace = project_root.as_ref().map(|root| {
            root.canonicalize()
                .unwrap_or_else(|_| root.to_path_buf())
                .to_string_lossy()
                .into_owned()
        });
        Self::with_project_namespace(profile_root, project_root, trust_project, project_namespace)
    }

    /// Create a catalog with an engine-owned stable project identity.
    ///
    /// Production callers should supply the canonical workspace id. The value
    /// is hashed before entering a state namespace and is never sent to code.
    #[must_use]
    pub fn with_project_namespace(
        profile_root: impl Into<PathBuf>,
        project_root: Option<PathBuf>,
        trust_project: bool,
        project_namespace: Option<String>,
    ) -> Self {
        Self {
            profile_root: profile_root.into(),
            project_root,
            trust_project,
            project_namespace: project_namespace
                .map(|identity| super::compiler::digest(identity.as_bytes())),
        }
    }

    /// Discover valid packages, with trusted project packages shadowing profile
    /// packages of the same id.
    pub fn discover(&self) -> Result<Vec<SkillDescriptor>, SkillError> {
        Ok(self
            .discover_internal()?
            .into_values()
            .map(|skill| skill.descriptor)
            .collect())
    }

    /// Search bounded summary metadata without loading instruction bodies.
    pub fn discover_page(
        &self,
        query: Option<&str>,
        cursor: Option<&str>,
        limit: Option<usize>,
    ) -> Result<SkillPage, SkillError> {
        if let Some(cursor) = cursor {
            validate_id(cursor)?;
        }
        let query = query.map(str::trim).filter(|query| !query.is_empty());
        if query.is_some_and(|query| query.len() > 256) {
            return Err(SkillError::Invalid(
                "skill discovery query exceeds 256 bytes".to_owned(),
            ));
        }
        let query = query.map(str::to_ascii_lowercase);
        let limit = limit.unwrap_or(16).clamp(1, MAX_SKILL_PAGE_SIZE);
        let mut rows = self
            .discover_internal()?
            .into_values()
            .filter(|skill| cursor.is_none_or(|cursor| skill.descriptor.id.as_str() > cursor))
            .filter(|skill| {
                query.as_ref().is_none_or(|query| {
                    skill.descriptor.id.to_ascii_lowercase().contains(query)
                        || skill.descriptor.name.to_ascii_lowercase().contains(query)
                        || skill
                            .descriptor
                            .summary
                            .to_ascii_lowercase()
                            .contains(query)
                })
            })
            .take(limit.saturating_add(1))
            .map(|skill| SkillSummary {
                id: skill.descriptor.id,
                name: skill.descriptor.name,
                summary: skill.descriptor.summary,
                origin: skill.descriptor.origin,
            })
            .collect::<Vec<_>>();
        let has_more = rows.len() > limit;
        rows.truncate(limit);
        let next_cursor = has_more
            .then(|| rows.last().map(|row| row.id.clone()))
            .flatten();
        Ok(SkillPage {
            skills: rows,
            next_cursor,
        })
    }

    /// Load the one selected instruction body.
    pub fn inspect(&self, skill_id: &str) -> Result<SkillDescriptor, SkillError> {
        validate_id(skill_id)?;
        self.discover_internal()?
            .remove(skill_id)
            .map(|skill| skill.descriptor)
            .ok_or_else(|| SkillError::NotFound(skill_id.to_owned()))
    }

    /// Resolve, validate, and digest-pin a callable `.ts`/`.js` module.
    pub fn resolve_module(
        &self,
        skill_id: &str,
        module: &str,
    ) -> Result<ResolvedSkillModule, SkillError> {
        validate_id(skill_id)?;
        let skills = self.discover_internal()?;
        let skill = skills
            .get(skill_id)
            .ok_or_else(|| SkillError::NotFound(skill_id.to_owned()))?;
        let relative = safe_relative_module(module)?;
        let candidate = skill.root.join(&relative);
        let canonical = candidate.canonicalize()?;
        let canonical_root = skill.root.canonicalize()?;
        if !canonical.starts_with(&canonical_root) {
            return Err(SkillError::Invalid(
                "skill module escapes its package root".to_owned(),
            ));
        }
        let metadata = fs::metadata(&canonical)?;
        if !metadata.is_file() || metadata.len() > MAX_MODULE_BYTES as u64 {
            return Err(SkillError::Invalid(format!(
                "skill module must be a file no larger than {MAX_MODULE_BYTES} bytes"
            )));
        }
        let source = fs::read_to_string(&canonical)?;
        let compiled = compile_typescript(&source, SourceKind::SkillModule)?;
        Ok(resolved(skill, module, compiled))
    }

    fn discover_internal(&self) -> Result<BTreeMap<String, FoundSkill>, SkillError> {
        let mut found = BTreeMap::new();
        scan_root(
            &self.profile_root,
            SkillOrigin::Profile,
            "profile",
            &mut found,
        )?;
        if self.trust_project {
            if let Some(project_root) = &self.project_root {
                let namespace = self.project_namespace.as_deref().ok_or_else(|| {
                    SkillError::Invalid(
                        "trusted project skills require an engine-derived project identity"
                            .to_owned(),
                    )
                })?;
                scan_root(project_root, SkillOrigin::Project, namespace, &mut found)?;
            }
        }
        if found.len() > MAX_SKILLS {
            return Err(SkillError::Invalid(format!(
                "skill catalog exceeds the {MAX_SKILLS} package limit"
            )));
        }
        Ok(found)
    }
}

fn scan_root(
    root: &Path,
    origin: SkillOrigin,
    owner_namespace: &str,
    output: &mut BTreeMap<String, FoundSkill>,
) -> Result<(), SkillError> {
    if !root.exists() {
        return Ok(());
    }
    let canonical_root = root.canonicalize()?;
    let mut entries = fs::read_dir(&canonical_root)?.collect::<Result<Vec<_>, _>>()?;
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for entry in entries {
        if output.len() >= MAX_SKILLS {
            return Err(SkillError::Invalid(format!(
                "skill catalog exceeds the {MAX_SKILLS} package limit"
            )));
        }
        let file_type = entry.file_type()?;
        if !file_type.is_dir() || file_type.is_symlink() {
            continue;
        }
        let package_root = entry.path().canonicalize()?;
        if !package_root.starts_with(&canonical_root) {
            continue;
        }
        let manifest = package_root.join("SKILL.md");
        if !manifest.is_file() {
            continue;
        }
        let canonical_manifest = manifest.canonicalize()?;
        if !canonical_manifest.starts_with(&package_root) {
            return Err(SkillError::Invalid(
                "SKILL.md escapes its package root".to_owned(),
            ));
        }
        if fs::metadata(&canonical_manifest)?.len() > MAX_MANIFEST_BYTES as u64 {
            continue;
        }
        let contents = fs::read_to_string(&canonical_manifest)?;
        let descriptor = parse_manifest(&contents, origin)?;
        let folder = entry.file_name().to_string_lossy().into_owned();
        if folder != descriptor.id {
            return Err(SkillError::Invalid(format!(
                "skill folder '{folder}' does not match id '{}'",
                descriptor.id
            )));
        }
        output.insert(
            descriptor.id.clone(),
            FoundSkill {
                state_namespace: match origin {
                    SkillOrigin::Profile => format!("skill:profile:{}", descriptor.id),
                    SkillOrigin::Project => format!(
                        "skill:project:{}:{}",
                        &owner_namespace[..owner_namespace.len().min(32)],
                        descriptor.id
                    ),
                },
                descriptor,
                root: package_root,
            },
        );
    }
    Ok(())
}

fn parse_manifest(contents: &str, origin: SkillOrigin) -> Result<SkillDescriptor, SkillError> {
    let mut lines = contents.lines();
    if lines.next() != Some("---") {
        return Err(SkillError::Invalid(
            "SKILL.md must begin with YAML-like front matter".to_owned(),
        ));
    }
    let mut id = None;
    let mut name = None;
    let mut summary = None;
    let mut ended = false;
    for line in lines.by_ref() {
        if line == "---" {
            ended = true;
            break;
        }
        let Some((key, value)) = line.split_once(':') else {
            return Err(SkillError::Invalid(format!(
                "invalid SKILL.md front-matter line '{line}'"
            )));
        };
        let value = value.trim().trim_matches('"').trim_matches('\'');
        match key.trim() {
            "id" => id = Some(value.to_owned()),
            "name" => name = Some(value.to_owned()),
            "summary" => summary = Some(value.to_owned()),
            _ => {}
        }
    }
    if !ended {
        return Err(SkillError::Invalid(
            "SKILL.md front matter is not terminated".to_owned(),
        ));
    }
    let id = id.ok_or_else(|| SkillError::Invalid("SKILL.md is missing id".to_owned()))?;
    validate_id(&id)?;
    let name = name.ok_or_else(|| SkillError::Invalid("SKILL.md is missing name".to_owned()))?;
    let summary =
        summary.ok_or_else(|| SkillError::Invalid("SKILL.md is missing summary".to_owned()))?;
    if name.is_empty() || name.len() > 120 || summary.is_empty() || summary.len() > 512 {
        return Err(SkillError::Invalid(
            "skill name/summary exceeds its bounded contract".to_owned(),
        ));
    }
    let instructions = lines.collect::<Vec<_>>().join("\n").trim().to_owned();
    Ok(SkillDescriptor {
        id,
        name,
        summary,
        instructions,
        origin,
    })
}

fn validate_id(id: &str) -> Result<(), SkillError> {
    if id.is_empty()
        || id.len() > 80
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        || id == "."
        || id == ".."
    {
        return Err(SkillError::Invalid(format!("invalid skill id '{id}'")));
    }
    Ok(())
}

fn safe_relative_module(module: &str) -> Result<PathBuf, SkillError> {
    let path = Path::new(module);
    let valid_extension = matches!(
        path.extension().and_then(|value| value.to_str()),
        Some("ts" | "js")
    );
    if module.is_empty()
        || path.is_absolute()
        || !valid_extension
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(SkillError::Invalid(format!(
            "invalid skill module path '{module}'"
        )));
    }
    Ok(path.to_path_buf())
}

fn resolved(skill: &FoundSkill, module: &str, compiled: CompiledSource) -> ResolvedSkillModule {
    ResolvedSkillModule {
        skill: skill.descriptor.clone(),
        module: module.to_owned(),
        source_digest: compiled.source_digest,
        compiled_digest: compiled.compiled_digest,
        javascript: compiled.javascript,
        state_namespace: skill.state_namespace.clone(),
    }
}

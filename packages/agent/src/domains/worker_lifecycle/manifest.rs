use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{FunctionId, RiskLevel};
use crate::shared::server::errors::CapabilityError;

use super::Deps;
use super::errors::{engine_error, invalid_params};
use super::{DEFAULT_CONFORMANCE_TIMEOUT_MS, PACKAGE_SCHEMA_VERSION, SOURCE_KIND_LOCAL_FILESYSTEM};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WorkerPackageManifest {
    pub(super) schema_version: String,
    pub(super) package_id: String,
    pub(super) package_version: String,
    pub(super) package_digest: String,
    pub(super) provenance: Value,
    pub(super) source: PackageSource,
    pub(super) worker_id: String,
    pub(super) namespace_claims: Vec<String>,
    pub(super) launch_command: Vec<String>,
    pub(super) working_directory: String,
    pub(super) env_allowlist: Vec<String>,
    pub(super) expected_functions: Vec<String>,
    pub(super) expected_triggers: Vec<String>,
    pub(super) requested_grants: RequestedGrantPolicy,
    pub(super) conformance_policy: ConformancePolicy,
    pub(super) rollback_policy: RollbackPolicy,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PackageSource {
    pub(super) kind: String,
    pub(super) path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RequestedGrantPolicy {
    pub(super) authority_scopes: Vec<String>,
    pub(super) resource_kinds: Vec<String>,
    pub(super) file_roots: Vec<String>,
    pub(super) network_policy: String,
    pub(super) max_risk: String,
    #[serde(default = "default_budget")]
    pub(super) budget: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ConformancePolicy {
    #[serde(default = "default_conformance_timeout_ms")]
    pub(super) timeout_ms: u64,
    #[serde(default)]
    pub(super) require_exact_functions: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RollbackPolicy {
    pub(super) on_failure: String,
}

#[derive(Clone, Debug)]
pub(super) struct ValidatedPackage {
    pub(super) manifest: WorkerPackageManifest,
    pub(super) source_root: PathBuf,
    pub(super) working_directory: PathBuf,
    pub(super) argv: Vec<String>,
    pub(super) env_keys: Vec<String>,
    pub(super) risk_level: RiskLevel,
    pub(super) file_roots: Vec<String>,
}

fn default_budget() -> Value {
    json!({"class": "worker_lifecycle", "remainingInvocations": 1})
}

fn default_conformance_timeout_ms() -> u64 {
    DEFAULT_CONFORMANCE_TIMEOUT_MS
}

pub(super) fn manifest_from_payload(
    payload: &Value,
) -> Result<WorkerPackageManifest, CapabilityError> {
    let manifest = payload
        .get("manifest")
        .ok_or_else(|| invalid_params("missing manifest"))?;
    serde_json::from_value(manifest.clone())
        .map_err(|error| invalid_params(format!("invalid worker package manifest: {error}")))
}

pub(super) fn validate_manifest_shape(
    manifest: &WorkerPackageManifest,
) -> Result<(), CapabilityError> {
    if manifest.schema_version != PACKAGE_SCHEMA_VERSION {
        return Err(invalid_params(format!(
            "manifest schemaVersion must be {PACKAGE_SCHEMA_VERSION}"
        )));
    }
    validate_tokenish("packageId", &manifest.package_id, false)?;
    validate_tokenish("packageVersion", &manifest.package_version, false)?;
    validate_digest(&manifest.package_digest)?;
    validate_tokenish("workerId", &manifest.worker_id, false)?;
    if manifest.source.kind != SOURCE_KIND_LOCAL_FILESYSTEM {
        return Err(invalid_params(
            "manifest source.kind must be local_filesystem".to_owned(),
        ));
    }
    if manifest.source.path.trim().is_empty() {
        return Err(invalid_params("manifest source.path must not be empty"));
    }
    if manifest
        .provenance
        .as_object()
        .is_none_or(serde_json::Map::is_empty)
    {
        return Err(invalid_params(
            "manifest provenance must be a non-empty object",
        ));
    }
    if manifest.namespace_claims.is_empty() {
        return Err(invalid_params("manifest namespaceClaims must not be empty"));
    }
    for namespace in &manifest.namespace_claims {
        validate_tokenish("namespaceClaim", namespace, false)?;
        reject_wildcard("namespaceClaim", namespace)?;
    }
    if manifest.launch_command.is_empty() {
        return Err(invalid_params("manifest launchCommand must not be empty"));
    }
    for value in &manifest.launch_command {
        reject_shell_fragment("launchCommand", value)?;
    }
    if manifest.working_directory.trim().is_empty() {
        return Err(invalid_params(
            "manifest workingDirectory must not be empty",
        ));
    }
    for key in &manifest.env_allowlist {
        validate_env_key(key)?;
    }
    for function in &manifest.expected_functions {
        FunctionId::new(function.clone()).map_err(engine_error)?;
        ensure_function_owned_by_namespace(function, &manifest.namespace_claims)?;
    }
    for trigger in &manifest.expected_triggers {
        validate_tokenish("expectedTrigger", trigger, false)?;
        ensure_trigger_owned_by_namespace(trigger, &manifest.namespace_claims)?;
    }
    validate_requested_grants(&manifest.requested_grants)?;
    if manifest.conformance_policy.timeout_ms == 0
        || manifest.conformance_policy.timeout_ms > 60_000
    {
        return Err(invalid_params(
            "manifest conformancePolicy.timeoutMs must be between 1 and 60000",
        ));
    }
    if !matches!(
        manifest.rollback_policy.on_failure.as_str(),
        "stop_worker" | "disable_package" | "retire_package"
    ) {
        return Err(invalid_params(
            "manifest rollbackPolicy.onFailure must be stop_worker, disable_package, or retire_package",
        ));
    }
    Ok(())
}

pub(super) fn validate_manifest_full(
    manifest: WorkerPackageManifest,
    deps: &Deps,
) -> Result<ValidatedPackage, CapabilityError> {
    validate_manifest_shape(&manifest)?;
    let package_root = ensure_package_root(&deps.package_root)?;
    let source_root = canonical_under_root(&package_root, &manifest.source.path, "source.path")?;
    let working_directory = canonical_under_root(
        &source_root,
        &manifest.working_directory,
        "workingDirectory",
    )?;
    if !working_directory.is_dir() {
        return Err(invalid_params(format!(
            "workingDirectory is not a directory: {}",
            working_directory.display()
        )));
    }
    let argv = canonical_launch_argv(&source_root, &manifest.launch_command)?;
    let file_roots = grant_file_roots(&source_root, &manifest.requested_grants.file_roots)?;
    let risk_level = parse_risk(&manifest.requested_grants.max_risk)?;
    Ok(ValidatedPackage {
        env_keys: manifest.env_allowlist.clone(),
        manifest,
        source_root,
        working_directory,
        argv,
        risk_level,
        file_roots,
    })
}

fn ensure_package_root(package_root: &Path) -> Result<PathBuf, CapabilityError> {
    std::fs::create_dir_all(package_root).map_err(|error| {
        invalid_params(format!(
            "create approved worker package root {}: {error}",
            package_root.display()
        ))
    })?;
    package_root.canonicalize().map_err(|error| {
        invalid_params(format!(
            "canonicalize approved worker package root {}: {error}",
            package_root.display()
        ))
    })
}

fn canonical_under_root(root: &Path, raw: &str, label: &str) -> Result<PathBuf, CapabilityError> {
    let candidate = if Path::new(raw).is_absolute() {
        PathBuf::from(raw)
    } else {
        root.join(raw)
    };
    let canonical = candidate
        .canonicalize()
        .map_err(|error| invalid_params(format!("canonicalize {label} {raw:?}: {error}")))?;
    if !canonical.starts_with(root) {
        return Err(invalid_params(format!(
            "{label} must stay under approved root {}",
            root.display()
        )));
    }
    Ok(canonical)
}

fn canonical_launch_argv(
    source_root: &Path,
    launch_command: &[String],
) -> Result<Vec<String>, CapabilityError> {
    let program = canonical_under_root(source_root, &launch_command[0], "launchCommand[0]")?;
    if !program.is_file() {
        return Err(invalid_params(format!(
            "launchCommand[0] is not a file: {}",
            program.display()
        )));
    }
    if program
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(is_shell_program)
    {
        return Err(invalid_params(
            "worker launchCommand[0] must not be a shell".to_owned(),
        ));
    }
    let mut argv = vec![program.display().to_string()];
    argv.extend(launch_command.iter().skip(1).cloned());
    Ok(argv)
}

fn grant_file_roots(
    source_root: &Path,
    requested_roots: &[String],
) -> Result<Vec<String>, CapabilityError> {
    let mut roots = vec![source_root.display().to_string()];
    for root in requested_roots {
        reject_wildcard("requestedGrants.fileRoots", root)?;
        let canonical = canonical_under_root(source_root, root, "requestedGrants.fileRoots")?;
        roots.push(canonical.display().to_string());
    }
    roots.sort();
    roots.dedup();
    Ok(roots)
}

fn validate_requested_grants(requested: &RequestedGrantPolicy) -> Result<(), CapabilityError> {
    for scope in &requested.authority_scopes {
        validate_tokenish("requestedGrants.authorityScopes", scope, true)?;
        reject_wildcard("requestedGrants.authorityScopes", scope)?;
    }
    for kind in &requested.resource_kinds {
        validate_tokenish("requestedGrants.resourceKinds", kind, true)?;
        reject_wildcard("requestedGrants.resourceKinds", kind)?;
    }
    for root in &requested.file_roots {
        reject_wildcard("requestedGrants.fileRoots", root)?;
    }
    if !matches!(
        requested.network_policy.as_str(),
        "none" | "loopback" | "declared"
    ) {
        return Err(invalid_params(
            "requestedGrants.networkPolicy must be none, loopback, or declared",
        ));
    }
    let _ = parse_risk(&requested.max_risk)?;
    Ok(())
}

pub(super) fn validate_tokenish(
    label: &str,
    value: &str,
    allow_colon: bool,
) -> Result<(), CapabilityError> {
    if value.trim().is_empty()
        || value.len() > 160
        || !value.chars().all(|ch| {
            ch.is_ascii_alphanumeric()
                || matches!(ch, '_' | '-' | '.')
                || (allow_colon && ch == ':')
        })
    {
        return Err(invalid_params(format!("invalid {label} {value:?}")));
    }
    Ok(())
}

fn validate_digest(value: &str) -> Result<(), CapabilityError> {
    let Some(hex) = value.strip_prefix("sha256:") else {
        return Err(invalid_params("packageDigest must start with sha256:"));
    };
    if hex.len() != 64 || !hex.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(invalid_params("packageDigest must be a sha256 hex digest"));
    }
    Ok(())
}

fn reject_wildcard(label: &str, value: &str) -> Result<(), CapabilityError> {
    if value == "*" || value.contains('*') {
        return Err(invalid_params(format!(
            "{label} must not contain wildcards"
        )));
    }
    Ok(())
}

fn validate_env_key(value: &str) -> Result<(), CapabilityError> {
    if value.is_empty()
        || value.len() > 80
        || !value
            .chars()
            .all(|ch| ch.is_ascii_uppercase() || ch.is_ascii_digit() || ch == '_')
    {
        return Err(invalid_params(format!(
            "invalid envAllowlist key {value:?}"
        )));
    }
    Ok(())
}

fn reject_shell_fragment(label: &str, value: &str) -> Result<(), CapabilityError> {
    if value.trim().is_empty() {
        return Err(invalid_params(format!("{label} entries must not be empty")));
    }
    let suspicious = [";", "&&", "||", "|", "`", "$(", "\n", "\r", ">", "<"];
    if suspicious.iter().any(|needle| value.contains(needle)) {
        return Err(invalid_params(format!(
            "{label} must be argv entries, not shell fragments"
        )));
    }
    Ok(())
}

fn is_shell_program(value: &str) -> bool {
    matches!(
        value,
        "sh" | "bash" | "zsh" | "fish" | "dash" | "cmd" | "powershell" | "pwsh"
    )
}

fn ensure_function_owned_by_namespace(
    function: &str,
    namespaces: &[String],
) -> Result<(), CapabilityError> {
    let namespace = function
        .split_once("::")
        .map(|(namespace, _)| namespace)
        .ok_or_else(|| {
            invalid_params(format!("function id {function} must use namespace::name"))
        })?;
    if namespaces.iter().any(|claim| claim == namespace) {
        Ok(())
    } else {
        Err(invalid_params(format!(
            "expected function {function} is outside namespaceClaims"
        )))
    }
}

fn ensure_trigger_owned_by_namespace(
    trigger: &str,
    namespaces: &[String],
) -> Result<(), CapabilityError> {
    if namespaces
        .iter()
        .any(|claim| trigger == claim || trigger.starts_with(&format!("{claim}:")))
    {
        Ok(())
    } else {
        Err(invalid_params(format!(
            "expected trigger {trigger} is outside namespaceClaims"
        )))
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel, CapabilityError> {
    match value {
        "low" | "Low" => Ok(RiskLevel::Low),
        "medium" | "Medium" => Ok(RiskLevel::Medium),
        "high" | "High" => Ok(RiskLevel::High),
        "critical" | "Critical" => Ok(RiskLevel::Critical),
        _ => Err(invalid_params(
            "requestedGrants.maxRisk must be low, medium, high, or critical",
        )),
    }
}

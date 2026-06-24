use std::fs;
use std::io;
use std::path::Path;

use sha2::{Digest, Sha256};

use super::super::paths::{dirs, files};
use super::validation::validate_profiles_file_ref;
use super::{AgentExecutionSpec, CompiledProfileFile, ProfileDocument, USER_PROFILE};

pub(super) fn compile_agent_execution_spec(
    home: &Path,
    name: &str,
    document: ProfileDocument,
    candidate_profiles: &[String],
) -> io::Result<AgentExecutionSpec> {
    let mut spec = AgentExecutionSpec::from_document_uncompiled(document);
    let mut source_files = candidate_profiles
        .iter()
        .map(|profile| {
            home.join(dirs::PROFILES)
                .join(profile)
                .join(files::PROFILE_TOML)
        })
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();
    let user_overlay = home
        .join(dirs::PROFILES)
        .join(USER_PROFILE)
        .join(files::PROFILE_TOML);
    if name != USER_PROFILE && user_overlay.is_file() {
        source_files.push(user_overlay);
    }

    let auth_registry =
        compile_profiles_file(home, name, "auth.registry", &spec.document.auth.registry)?;
    source_files.push(auth_registry.source_path.clone());
    spec.auth_registry = Some(auth_registry);

    source_files.sort();
    source_files.dedup();
    spec.source_files = source_files;
    Ok(spec)
}

fn compile_profiles_file(
    home: &Path,
    name: &str,
    label: &str,
    rel: &str,
) -> io::Result<CompiledProfileFile> {
    let source_path = validate_profiles_file_ref(home, name, label, rel)?;
    let content = fs::read_to_string(&source_path).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!(
                "failed to read {label} file {}: {error}",
                source_path.display()
            ),
        )
    })?;
    Ok(CompiledProfileFile {
        relative_ref: rel.to_string(),
        hash: sha256_hex(content.as_bytes()),
        source_path,
        content,
    })
}

pub(super) fn agent_execution_spec_hash(raw_string: &str, spec: &AgentExecutionSpec) -> String {
    let mut files = Vec::new();
    if let Some(file) = &spec.auth_registry {
        files.push(("auth.registry".to_string(), file));
    }
    files.sort_by(|left, right| left.0.cmp(&right.0));

    let mut hasher = Sha256::new();
    hasher.update(b"profile.raw\0");
    hasher.update(raw_string.as_bytes());
    hasher.update(b"\0profile.files\0");
    for (label, file) in files {
        hasher.update(label.as_bytes());
        hasher.update([0]);
        hasher.update(file.relative_ref.as_bytes());
        hasher.update([0]);
        hasher.update(file.hash.as_bytes());
        hasher.update([0]);
    }
    hex::encode(hasher.finalize())
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex::encode(digest)
}

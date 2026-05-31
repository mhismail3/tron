use std::fs;
use std::io;
use std::path::Path;

use sha2::{Digest, Sha256};

use super::super::paths::{dirs, files};
use super::validation::{validate_profile_file_ref, validate_profiles_file_ref};
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

    for (entrypoint, entry) in &spec.document.entrypoints {
        if let Some(prompt) = &entry.prompt {
            let compiled = compile_profile_file(
                home,
                name,
                candidate_profiles,
                &format!("entrypoints.{entrypoint}.prompt"),
                prompt,
            )?;
            source_files.push(compiled.source_path.clone());
            spec.entrypoint_prompts.insert(entrypoint.clone(), compiled);
        }
    }
    for (process_id, process) in &spec.document.processes {
        if let Some(prompt) = &process.prompt {
            let compiled = compile_profile_file(
                home,
                name,
                candidate_profiles,
                &format!("processes.{process_id}.prompt"),
                prompt,
            )?;
            source_files.push(compiled.source_path.clone());
            spec.process_prompts.insert(process_id.clone(), compiled);
        }
    }
    for (provider, policy) in &spec.document.provider_policies {
        if let Some(prompt) = &policy.prompt {
            let compiled = compile_profile_file(
                home,
                name,
                candidate_profiles,
                &format!("providerPolicies.{provider}.prompt"),
                prompt,
            )?;
            source_files.push(compiled.source_path.clone());
            spec.provider_prompts.insert(provider.clone(), compiled);
        }
    }
    for (policy_id, policy) in &spec.document.context_policies {
        if let Some(blocks) = &policy.blocks {
            let compiled = compile_profile_file(
                home,
                name,
                candidate_profiles,
                &format!("contextPolicies.{policy_id}.blocks"),
                blocks,
            )?;
            source_files.push(compiled.source_path.clone());
            spec.context_manifests.insert(policy_id.clone(), compiled);
        }
    }
    source_files.sort();
    source_files.dedup();
    spec.source_files = source_files;
    Ok(spec)
}

fn compile_profile_file(
    home: &Path,
    name: &str,
    candidate_profiles: &[String],
    label: &str,
    rel: &str,
) -> io::Result<CompiledProfileFile> {
    let source_path = validate_profile_file_ref(home, name, candidate_profiles, label, rel)?;
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
    files.extend(
        spec.entrypoint_prompts
            .iter()
            .map(|(id, file)| (format!("entrypoints.{id}.prompt"), file)),
    );
    files.extend(
        spec.process_prompts
            .iter()
            .map(|(id, file)| (format!("processes.{id}.prompt"), file)),
    );
    files.extend(
        spec.provider_prompts
            .iter()
            .map(|(id, file)| (format!("providerPolicies.{id}.prompt"), file)),
    );
    files.extend(
        spec.context_manifests
            .iter()
            .map(|(id, file)| (format!("contextPolicies.{id}.blocks"), file)),
    );
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

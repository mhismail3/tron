//! Capability contracts owned by the filesystem domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["filesystem.changes"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("filesystem::list_dir", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("List entries in a known directory, optionally including hidden files and bounding the number of returned entries. Use filesystem::find or filesystem::glob before list_dir when a path is only a guessed module or folder name.")
            .tags(vec!["list", "directory", "folder", "ls", "files", "workspace"])
            .request_schema(json!({"additionalProperties":false,"properties":{"maxResults":{"type":"integer"},"path":{"type":"string"},"sessionId":{"type":"string"},"showHidden":{"type":"boolean"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"entries":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"parent":{"type":["string","null"]},"path":{"type":"string"}},"required":["path","parent","entries"],"type":"object"}))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::list_dir","payload":{"path":".","maxResults":20},"reason":"List the current worktree directory."})])
            .build()?,
        CapabilityContract::new("filesystem::get_home", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("Return the user's home path and commonly useful filesystem locations.")
            .tags(vec!["home", "directory", "path", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"homePath":{"type":"string"},"suggestedPaths":{"items":{"additionalProperties":false,"properties":{"exists":{"type":"boolean"},"name":{"type":"string"},"path":{"type":"string"}},"required":["name","path","exists"],"type":"object"},"type":"array"}},"required":["homePath","suggestedPaths"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::create_dir", "filesystem", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("filesystem.write"))
            .description("Create a directory and any missing parent directories.")
            .tags(vec!["mkdir", "create directory", "folder", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path"],"type":"object"}))
            .response_schema(filesystem_resource_backed_response(json!({"created":{"type":"boolean"},"path":{"type":"string"}}), vec!["created", "path"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["materialized_file"]))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("filesystem::read_file", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("Read a file from the workspace or allowed filesystem roots, optionally bounded by 1-based line numbers.")
            .tags(vec!["read", "file", "open", "cat", "content", "line", "lines", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"endLine":{"minimum":1,"type":"integer"},"path":{"type":"string"},"sessionId":{"type":"string"},"startLine":{"minimum":1,"type":"integer"},"workspaceId":{"type":"string"}},"required":["path"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"content":{"type":"string"},"endLine":{"type":"integer"},"path":{"type":"string"},"startLine":{"type":"integer"}},"required":["content","path"],"type":"object"}))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::read_file","payload":{"path":"README.md","startLine":1,"endLine":20},"reason":"Read the first 20 lines of the project README."})])
            .build()?,
        CapabilityContract::new("filesystem::write_file", "filesystem", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("filesystem.write"))
            .description("Create or overwrite a file with exact content.")
            .tags(vec!["write", "file", "save", "create file", "overwrite", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"content":{"type":"string"},"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","content"],"type":"object"}))
            .response_schema(filesystem_resource_backed_response(json!({"bytesWritten":{"type":"integer"},"created":{"type":"boolean"},"path":{"type":"string"}}), vec!["path", "bytesWritten", "created"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["materialized_file"]))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "writes are audited with byte counts; callers should inspect/diff before replacing important content"))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::write_file","payload":{"path":"scratch/example.txt","content":"hello"},"idempotencyKey":"write-example-<turn>","reason":"Write a small example file."})])
            .build()?,
        CapabilityContract::new("filesystem::edit_file", "filesystem", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("filesystem.write"))
            .description("Edit a file by replacing an exact old string with a new string.")
            .tags(vec!["edit", "replace", "modify", "file", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"newString":{"type":"string"},"oldString":{"type":"string"},"path":{"type":"string"},"replaceAll":{"type":"boolean"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","oldString","newString"],"type":"object"}))
            .response_schema(filesystem_resource_backed_response(json!({"diff":{"type":"string"},"path":{"type":"string"},"replacements":{"type":"integer"}}), vec!["path", "replacements", "diff"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["materialized_file", "patch_proposal"]))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "the returned diff contains enough context for manual reversal when the edited file still exists"))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::edit_file","payload":{"path":"README.md","oldString":"old text","newString":"new text"},"idempotencyKey":"edit-readme-<turn>","reason":"Replace exact text in README.md."})])
            .build()?,
        CapabilityContract::new("filesystem::find", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("Find filesystem entries by glob-style pattern. Prefer this over filesystem::list_dir when locating a module, folder, or file whose exact path is unknown.")
            .tags(vec!["find", "glob", "file names", "paths", "search files", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"exclude":{"items":{"type":"string"},"type":"array"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"},"path":{"type":"string"},"pattern":{"type":"string"},"sessionId":{"type":"string"},"type":{"enum":["file","directory","all"],"type":"string"},"workspaceId":{"type":"string"}},"required":["pattern"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"matches":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"path":{"type":"string"},"truncated":{"type":"boolean"}},"required":["path","matches","truncated"],"type":"object"}))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::find","payload":{"pattern":"*.swift","path":"packages/ios-app","maxResults":20},"reason":"Find Swift files in the iOS app."})])
            .build()?,
        CapabilityContract::new("filesystem::glob", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("Expand a glob pattern into matching files or directories. Prefer this over filesystem::list_dir when locating a module, folder, or file whose exact path is unknown.")
            .tags(vec!["glob", "find", "pattern", "files", "paths", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"exclude":{"items":{"type":"string"},"type":"array"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"},"path":{"type":"string"},"pattern":{"type":"string"},"sessionId":{"type":"string"},"type":{"enum":["file","directory","all"],"type":"string"},"workspaceId":{"type":"string"}},"required":["pattern"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"matches":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"path":{"type":"string"},"truncated":{"type":"boolean"}},"required":["path","matches","truncated"],"type":"object"}))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::glob","payload":{"pattern":"**/*.rs","path":"packages/agent/src","maxResults":50},"reason":"Find Rust source files."})])
            .build()?,
        CapabilityContract::new("filesystem::search_text", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("Search file contents by literal text by default, with optional regex mode (`regex: true`), file filtering, and context. Repo-root searches skip generated/heavy directories such as .git, target, node_modules, and .worktrees by default; set path to one of those directories explicitly only when that generated content is the intended target.")
            .tags(vec!["search", "grep", "rg", "text search", "regex", "content", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"context":{"type":"integer"},"filePattern":{"type":"string"},"maxResults":{"type":"integer"},"path":{"type":"string"},"pattern":{"type":"string"},"regex":{"type":"boolean"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["pattern"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"matches":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"path":{"type":"string"},"truncated":{"type":"boolean"}},"required":["path","matches","truncated"],"type":"object"}))
            .examples(vec![
                json!({"mode":"invoke","contractId":"filesystem::search_text","payload":{"pattern":"AgentCapabilityRecipe","path":"packages/agent/src","maxResults":20},"reason":"Search source files for a literal symbol."}),
                json!({"mode":"invoke","contractId":"filesystem::search_text","payload":{"pattern":"register_(function|trigger)","regex":true,"path":"packages/agent/src","maxResults":20},"reason":"Search source files with an explicit regex."})
            ])
            .build()?,
        CapabilityContract::new("filesystem::diff", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .description("Preview a unified diff between an existing file and proposed new content without writing.")
            .tags(vec!["diff", "preview", "dry run", "file", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"newContent":{"type":"string"},"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","newContent"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"diff":{"type":"string"},"path":{"type":"string"}},"required":["path","diff"],"type":"object"}))
            .examples(vec![json!({"mode":"invoke","contractId":"filesystem::diff","payload":{"path":"README.md","newContent":"new file content"},"reason":"Preview a proposed README change."})])
            .build()?,
        CapabilityContract::new("filesystem::apply_patch", "filesystem", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("filesystem.write"))
            .description("Apply an exact-string patch to a file and return the resulting diff. To append bytes, pass oldString as an empty string and newString as the exact bytes to append.")
            .tags(vec!["patch", "apply patch", "edit", "replace", "append", "file", "filesystem"])
            .request_schema(json!({"additionalProperties":false,"properties":{"newString":{"type":"string"},"oldString":{"type":"string"},"path":{"type":"string"},"replaceAll":{"type":"boolean"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","oldString","newString"],"type":"object"}))
            .response_schema(filesystem_resource_backed_response(json!({"diff":{"type":"string"},"path":{"type":"string"},"replacements":{"type":"integer"}}), vec!["path", "replacements", "diff"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["materialized_file", "patch_proposal"]))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "patch edits return a diff for manual reversal when the edited file still exists"))
            .examples(vec![
                json!({"mode":"invoke","contractId":"filesystem::apply_patch","payload":{"path":"README.md","oldString":"old text","newString":"new text"},"idempotencyKey":"patch-readme-<turn>","reason":"Apply an exact text replacement."}),
                json!({"mode":"invoke","contractId":"filesystem::apply_patch","payload":{"path":"README.md","oldString":"","newString":"Appended line\n"},"idempotencyKey":"append-readme-<turn>","reason":"Append an exact line to README.md."})
            ])
            .build()?
    ])
}

fn filesystem_resource_backed_response(
    properties: serde_json::Value,
    mut required: Vec<&'static str>,
) -> serde_json::Value {
    let mut properties = properties.as_object().cloned().unwrap_or_default();
    properties.insert("resourceRefs".to_owned(), resource_refs_schema());
    required.push("resourceRefs");
    json!({
        "additionalProperties": false,
        "properties": properties,
        "required": required,
        "type": "object"
    })
}

fn resource_refs_schema() -> serde_json::Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["resourceId", "kind", "role"],
            "additionalProperties": false,
            "properties": {
                "resourceId": {"type": "string"},
                "kind": {"type": "string"},
                "versionId": {"type": "string"},
                "role": {"type": "string"},
                "contentHash": {"type": "string"},
                "relation": {"type": "string"}
            }
        }
    })
}

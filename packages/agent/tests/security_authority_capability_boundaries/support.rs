use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/security-authority-capability-boundaries-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/security-authority-capability-boundaries-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/security-authority-capability-boundaries-inventory.md";
pub(super) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/security_authority_capability_boundaries_invariants.rs";

pub(super) const INVENTORY_HEADER: &str = "path\tlanguage\tsurface\tboundary_class\ttrusted_owner\tuntrusted_input\tauthority_source\tenforcement_point\tdeny_policy\tsecret_or_token_policy\ttest_evidence\tsacb_rows";

const SECURITY_MARKERS: &[&str] = &[
    "Authorization",
    "authorization",
    "Bearer",
    "bearer",
    "bearerToken",
    "accessToken",
    "refreshToken",
    "apiKey",
    "clientSecret",
    "auth.json",
    "Keychain",
    "UserDefaults",
    "/engine",
    "engine/workers",
    "ENGINE_INTERNAL_INVOKE_SCOPE",
    "engine.internal.invoke",
    "authority",
    "AuthorityGrant",
    "grant",
    "runtimeMetadata",
    "runtime_metadata",
    "RUNTIME_METADATA",
    "workingDirectory",
    "working_directory",
    "RUNTIME_METADATA_WORKING_DIRECTORY",
    "process_run",
    "file_read",
    "file_write",
    "filesystem_read",
    "filesystem_write",
    "filesystem_apply_patch",
    "Command::new",
    "networkPolicy",
    "network_policy",
    "DiagnosticsRedactor",
    "redact",
    "oauth",
    "OAuth",
    "secret",
    "credential",
    "Pairing",
    "paired",
    "tron://pair",
    "QRCode",
    "QR",
    "deep-link",
    "loopback",
    "WorkerToken",
    "worker token",
];

#[derive(Debug, Clone)]
pub(super) struct InventoryRow {
    pub(super) path: String,
    pub(super) language: String,
    pub(super) surface: String,
    pub(super) boundary_class: String,
    pub(super) trusted_owner: String,
    pub(super) untrusted_input: String,
    pub(super) authority_source: String,
    pub(super) enforcement_point: String,
    pub(super) deny_policy: String,
    pub(super) secret_or_token_policy: String,
    pub(super) test_evidence: String,
    pub(super) sacb_rows: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ScorecardRow {
    pub(super) row: String,
    pub(super) points: u32,
    pub(super) status: String,
}

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(super) fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

pub(super) fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

pub(super) fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn is_sacb_scanned_path(path: &str) -> bool {
    let in_scope = path.starts_with("packages/agent/")
        || path.starts_with("packages/ios-app/")
        || path.starts_with("packages/mac-app/")
        || path.starts_with("scripts/")
        || path.starts_with(".github/")
        || matches!(path, "README.md" | "CONTRIBUTING.md" | "AGENTS.md");
    if !in_scope {
        return false;
    }
    let allowed_extension = [
        ".rs", ".swift", ".sh", ".py", ".yml", ".yaml", ".md", ".tsv", ".toml", ".json", ".plist",
    ]
    .iter()
    .any(|extension| path.ends_with(extension))
        || path == "scripts/tron";
    if !allowed_extension {
        return false;
    }
    ![
        "packages/agent/src/domains/model/tokens/",
        "packages/agent/src/domains/agent/context/token_estimator",
        "packages/ios-app/Sources/Session/Timeline/Tokens/",
        "packages/ios-app/Tests/Session/Timeline/Tokens/",
    ]
    .iter()
    .any(|excluded| path.contains(excluded))
        && !(path.starts_with("packages/agent/src/domains/model/providers/")
            && path.contains("/types/models"))
}

pub(super) fn security_marker_paths() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| is_sacb_scanned_path(path))
        .filter(|path| repo_path(path).is_file())
        .filter(|path| {
            let source = read_repo_file(path);
            SECURITY_MARKERS
                .iter()
                .any(|marker| source.contains(marker))
        })
        .collect()
}

pub(super) fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SACB-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                points: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid SACB score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

pub(super) fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(
        header, INVENTORY_HEADER,
        "SACB inventory TSV header changed"
    );

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                12,
                "inventory row {} must have 12 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                path: columns[0].to_owned(),
                language: columns[1].to_owned(),
                surface: columns[2].to_owned(),
                boundary_class: columns[3].to_owned(),
                trusted_owner: columns[4].to_owned(),
                untrusted_input: columns[5].to_owned(),
                authority_source: columns[6].to_owned(),
                enforcement_point: columns[7].to_owned(),
                deny_policy: columns[8].to_owned(),
                secret_or_token_policy: columns[9].to_owned(),
                test_evidence: columns[10].to_owned(),
                sacb_rows: columns[11].to_owned(),
            }
        })
        .collect()
}

pub(super) fn inventory_by_path() -> BTreeMap<String, InventoryRow> {
    parse_inventory()
        .into_iter()
        .map(|row| (row.path.clone(), row))
        .collect()
}

use super::RulesIndex;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RuleFileLevel {
    Global,
    Project,
    Directory,
}

impl RuleFileLevel {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Global => "global",
            Self::Project => "project",
            Self::Directory => "directory",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RuleFile {
    pub(crate) path: PathBuf,
    pub(crate) relative_path: String,
    pub(crate) level: RuleFileLevel,
    pub(crate) depth: usize,
    pub(crate) size_bytes: usize,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct LoadedRules {
    pub(crate) merged_content: Option<String>,
    pub(crate) files: Vec<RuleFile>,
}

impl LoadedRules {
    pub(crate) fn total_size_bytes(&self) -> usize {
        self.files.iter().map(|f| f.size_bytes).sum()
    }

    pub(crate) fn merged_tokens_estimate(&self) -> u32 {
        #[allow(clippy::cast_possible_truncation)]
        {
            (self.total_size_bytes() / 4) as u32
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionContextArtifacts {
    pub(crate) rules: LoadedRules,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct ResolvedContextArtifacts {
    pub(crate) session: SessionContextArtifacts,
    pub(crate) rules_index: Option<RulesIndex>,
    pub(crate) workspace_id: Option<String>,
}

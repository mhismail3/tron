//! Error types for the skills system.

/// Errors that can occur during skill operations.
#[derive(Debug, thiserror::Error)]
pub enum SkillError {
    /// I/O error during filesystem operations.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// Skill not found by name.
    #[error("Skill not found: {0}")]
    NotFound(String),

    /// Skill file exceeds maximum size.
    #[error("Skill file too large: {path} ({size} bytes > {max} bytes)")]
    FileTooLarge {
        /// Path to the oversized file.
        path: String,
        /// Actual file size.
        size: u64,
        /// Maximum allowed size.
        max: u64,
    },

    /// Error parsing skill frontmatter.
    #[error("Parse error in {path}: {message}")]
    Parse {
        /// Path to the problematic file.
        path: String,
        /// Description of the parse error.
        message: String,
    },
}

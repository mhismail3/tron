//! Scheduling metadata for model-emitted primitive calls.

/// Controls how one model protocol call is scheduled relative to others.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExecutionMode {
    /// Execute concurrently with all other parallel capability calls.
    Parallel,
    /// Execute sequentially within a named group.
    Serialized(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn execution_mode_parallel_and_serialized_are_distinct() {
        assert_eq!(ExecutionMode::Parallel, ExecutionMode::Parallel);
        assert_ne!(
            ExecutionMode::Parallel,
            ExecutionMode::Serialized("execute".into())
        );
        assert_eq!(
            ExecutionMode::Serialized("execute".into()),
            ExecutionMode::Serialized("execute".into())
        );
    }
}

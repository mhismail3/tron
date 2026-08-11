//! Compatibility re-exports for process custody now owned by the core host.

pub(crate) use crate::domains::host::process_custody::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};

//! Filesystem free-space helpers.

use std::io;
use std::path::Path;

/// Return available space in MiB for the filesystem containing `path`.
pub fn available_megabytes(path: &Path) -> io::Result<u64> {
    let stats = rustix::fs::statvfs(path).map_err(io::Error::other)?;
    let free_bytes = u128::from(stats.f_frsize) * u128::from(stats.f_bavail);
    Ok((free_bytes / 1_048_576) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn available_megabytes_returns_value_for_tmp() {
        let free_mb = available_megabytes(Path::new("/tmp")).unwrap();
        assert!(free_mb > 0);
    }
}

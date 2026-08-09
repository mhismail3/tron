//! Private bounded PTY journal and screen-checkpoint persistence.
//!
//! Records preserve exact byte order for reconnect. Compaction replaces an
//! oversized log with one vt100 screen snapshot at the current sequence, so a
//! client can reset its renderer without replay storage growing without bound.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

use base64::Engine as _;

use super::{MAX_OUTPUT_CHUNK, MAX_REPLAY_BYTES, TerminalChunk, TerminalRecord};

pub(super) fn append_journal(path: &Path, sequence: u64, bytes: &[u8]) -> std::io::Result<()> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(&sequence.to_le_bytes())?;
    file.write_all(&(bytes.len() as u32).to_le_bytes())?;
    file.write_all(bytes)
}

pub(super) fn replace_journal(path: &Path, sequence: u64, bytes: &[u8]) -> std::io::Result<()> {
    let mut record = Vec::with_capacity(12 + bytes.len());
    record.extend_from_slice(&sequence.to_le_bytes());
    record.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    record.extend_from_slice(bytes);
    replace_private_file(path, &record)
}

pub(super) fn replace_private_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(temporary, path)
}

pub(super) fn terminal_snapshot(parser: &vt100::Parser) -> Vec<u8> {
    let mut snapshot = b"\x1b[2J\x1b[H".to_vec();
    snapshot.extend(parser.screen().state_formatted());
    snapshot
}

pub(super) fn read_journal(
    path: &Path,
    terminal_id: &str,
    generation: u64,
    after: u64,
) -> std::io::Result<Vec<TerminalChunk>> {
    let bytes = fs::read(path)?;
    if bytes.len() > MAX_REPLAY_BYTES + MAX_OUTPUT_CHUNK + 12 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "terminal journal exceeds its retention bound",
        ));
    }
    let mut cursor = 0;
    let mut chunks = Vec::new();
    while cursor < bytes.len() {
        if bytes.len().saturating_sub(cursor) < 12 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "terminal journal has a truncated header",
            ));
        }
        let mut sequence_bytes = [0_u8; 8];
        sequence_bytes.copy_from_slice(&bytes[cursor..cursor + 8]);
        let sequence = u64::from_le_bytes(sequence_bytes);
        let mut length_bytes = [0_u8; 4];
        length_bytes.copy_from_slice(&bytes[cursor + 8..cursor + 12]);
        let length = u32::from_le_bytes(length_bytes) as usize;
        cursor += 12;
        let end = cursor
            .checked_add(length)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "terminal journal has a truncated record",
                )
            })?;
        if sequence > after {
            chunks.push(TerminalChunk {
                terminal_id: terminal_id.to_owned(),
                generation,
                sequence,
                data_base64: base64::engine::general_purpose::STANDARD.encode(&bytes[cursor..end]),
            });
        }
        cursor = end;
    }
    Ok(chunks)
}

pub(super) fn retained(record: &TerminalRecord) -> bool {
    chrono::DateTime::parse_from_rfc3339(&record.retained_until)
        .is_ok_and(|until| until > chrono::Utc::now())
}

pub(super) fn private_dir(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

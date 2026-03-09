//! Core types for the transcription engine.

/// Result of transcribing an audio file.
#[derive(Debug, Clone)]
pub struct TranscriptionResult {
    /// The transcribed text.
    pub text: String,
    /// Detected language code (e.g. "en").
    pub language: String,
    /// Duration of the audio in seconds.
    pub duration_seconds: f64,
}

/// Errors that can occur during transcription.
#[derive(Debug, thiserror::Error)]
pub enum TranscriptionError {
    /// Sidecar setup failed (Python not found, venv creation, pip install).
    #[error("setup error: {0}")]
    Setup(String),

    /// Sidecar communication error (broken pipe, timeout, bad JSON).
    #[error("sidecar error: {0}")]
    Sidecar(String),

    /// I/O error (temp file write, process spawn).
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// Extension trait to reduce `.map_err()` boilerplate.
pub trait ResultExt<T> {
    /// Wrap the error as [`TranscriptionError::Setup`] with `context` prefix.
    fn setup(self, context: &str) -> Result<T, TranscriptionError>;
    /// Wrap the error as [`TranscriptionError::Sidecar`] with `context` prefix.
    fn sidecar(self, context: &str) -> Result<T, TranscriptionError>;
}

impl<T, E: std::fmt::Display> ResultExt<T> for Result<T, E> {
    fn setup(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::Setup(format!("{context}: {e}")))
    }
    fn sidecar(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::Sidecar(format!("{context}: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcription_result_fields() {
        let r = TranscriptionResult {
            text: "Hello world".into(),
            language: "en".into(),
            duration_seconds: 2.5,
        };
        assert_eq!(r.text, "Hello world");
        assert_eq!(r.language, "en");
        assert!((r.duration_seconds - 2.5).abs() < f64::EPSILON);
    }

    #[test]
    fn transcription_error_display() {
        let e = TranscriptionError::Setup("missing python".into());
        assert!(e.to_string().contains("missing python"));

        let e = TranscriptionError::Sidecar("broken pipe".into());
        assert!(e.to_string().contains("broken pipe"));
    }

    #[test]
    fn result_ext_setup_context() {
        let err: Result<(), &str> = Err("python not found");
        let mapped = err.setup("find_python");
        assert!(
            matches!(mapped, Err(TranscriptionError::Setup(s)) if s == "find_python: python not found")
        );
    }

    #[test]
    fn result_ext_sidecar_context() {
        let err: Result<(), &str> = Err("broken pipe");
        let mapped = err.sidecar("write request");
        assert!(
            matches!(mapped, Err(TranscriptionError::Sidecar(s)) if s == "write request: broken pipe")
        );
    }

    #[test]
    fn result_ext_ok_passthrough() {
        let ok: Result<i32, &str> = Ok(42);
        assert_eq!(ok.setup("ctx").unwrap(), 42);
        let ok: Result<i32, &str> = Ok(99);
        assert_eq!(ok.sidecar("ctx").unwrap(), 99);
    }

    #[test]
    fn result_ext_with_std_io_error() {
        let err: Result<(), std::io::Error> =
            Err(std::io::Error::new(std::io::ErrorKind::NotFound, "gone"));
        let mapped = err.setup("file read");
        assert!(matches!(mapped, Err(TranscriptionError::Setup(s)) if s.contains("gone")));
    }

    #[test]
    fn io_error_from_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::BrokenPipe, "pipe broken");
        let te: TranscriptionError = io_err.into();
        assert!(matches!(te, TranscriptionError::Io(_)));
        assert!(te.to_string().contains("pipe broken"));
    }
}

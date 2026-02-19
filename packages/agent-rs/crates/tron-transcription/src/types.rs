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
    /// Model files not found or failed to download.
    #[error("model not available: {0}")]
    ModelNotAvailable(String),

    /// ONNX Runtime session creation or inference failure.
    #[error("inference error: {0}")]
    Inference(String),

    /// Audio decoding failure (unsupported format, corrupt data).
    #[error("audio decode error: {0}")]
    AudioDecode(String),

    /// Resampling failure.
    #[error("resample error: {0}")]
    Resample(String),

    /// I/O error (file read/write).
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// Extension trait to reduce `.map_err()` boilerplate when wrapping errors into `TranscriptionError`.
pub trait ResultExt<T> {
    /// Wrap the error as [`TranscriptionError::Inference`] with `context` prefix.
    fn inference(self, context: &str) -> Result<T, TranscriptionError>;
    /// Wrap the error as [`TranscriptionError::AudioDecode`] with `context` prefix.
    fn audio_decode(self, context: &str) -> Result<T, TranscriptionError>;
    /// Wrap the error as [`TranscriptionError::Resample`] with `context` prefix.
    fn resample(self, context: &str) -> Result<T, TranscriptionError>;
    /// Wrap the error as [`TranscriptionError::ModelNotAvailable`] with `context` prefix.
    fn model(self, context: &str) -> Result<T, TranscriptionError>;
}

impl<T, E: std::fmt::Display> ResultExt<T> for Result<T, E> {
    fn inference(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::Inference(format!("{context}: {e}")))
    }
    fn audio_decode(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::AudioDecode(format!("{context}: {e}")))
    }
    fn resample(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::Resample(format!("{context}: {e}")))
    }
    fn model(self, context: &str) -> Result<T, TranscriptionError> {
        self.map_err(|e| TranscriptionError::ModelNotAvailable(format!("{context}: {e}")))
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
        assert_eq!(r.duration_seconds, 2.5);
    }

    #[test]
    fn transcription_error_display() {
        let e = TranscriptionError::ModelNotAvailable("missing encoder".into());
        assert!(e.to_string().contains("missing encoder"));

        let e = TranscriptionError::AudioDecode("corrupt header".into());
        assert!(e.to_string().contains("corrupt header"));
    }

    #[test]
    fn result_ext_inference_context() {
        let err: Result<(), &str> = Err("onnx failure");
        let mapped = err.inference("encoder run");
        assert!(matches!(mapped, Err(TranscriptionError::Inference(s)) if s == "encoder run: onnx failure"));
    }

    #[test]
    fn result_ext_audio_decode_context() {
        let err: Result<(), &str> = Err("corrupt header");
        let mapped = err.audio_decode("probe");
        assert!(matches!(mapped, Err(TranscriptionError::AudioDecode(s)) if s == "probe: corrupt header"));
    }

    #[test]
    fn result_ext_resample_context() {
        let err: Result<(), &str> = Err("ratio invalid");
        let mapped = err.resample("init");
        assert!(matches!(mapped, Err(TranscriptionError::Resample(s)) if s == "init: ratio invalid"));
    }

    #[test]
    fn result_ext_model_context() {
        let err: Result<(), &str> = Err("download failed");
        let mapped = err.model("ensure_model");
        assert!(matches!(mapped, Err(TranscriptionError::ModelNotAvailable(s)) if s == "ensure_model: download failed"));
    }

    #[test]
    fn result_ext_ok_passthrough() {
        let ok: Result<i32, &str> = Ok(42);
        assert_eq!(ok.inference("ctx").unwrap(), 42);
        let ok: Result<i32, &str> = Ok(99);
        assert_eq!(ok.audio_decode("ctx").unwrap(), 99);
    }

    #[test]
    fn result_ext_empty_error_message() {
        let err: Result<(), &str> = Err("");
        let mapped = err.inference("ctx");
        assert!(matches!(mapped, Err(TranscriptionError::Inference(s)) if s == "ctx: "));
    }

    #[test]
    fn result_ext_with_std_io_error() {
        let err: Result<(), std::io::Error> =
            Err(std::io::Error::new(std::io::ErrorKind::NotFound, "gone"));
        let mapped = err.inference("file read");
        assert!(matches!(mapped, Err(TranscriptionError::Inference(s)) if s.contains("gone")));
    }
}

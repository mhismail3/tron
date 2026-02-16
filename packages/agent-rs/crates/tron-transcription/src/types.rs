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
}

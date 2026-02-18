//! Audio decoding and resampling to 16kHz mono f32.

use std::io::Cursor;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::types::TranscriptionError;

/// Target sample rate for the transcription model.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Decode audio bytes into 16kHz mono f32 samples.
///
/// Supports WAV, M4A/AAC, and other formats via symphonia.
/// Automatically resamples to 16kHz and mixes to mono if needed.
pub fn decode_audio(data: &[u8], mime_type: &str) -> Result<(Vec<f32>, u32), TranscriptionError> {
    let cursor = Cursor::new(data.to_vec());
    let mss = MediaSourceStream::new(Box::new(cursor), Default::default());

    let mut hint = Hint::new();
    match mime_type {
        "audio/wav" | "audio/wave" | "audio/x-wav" => {
            let _ = hint.with_extension("wav");
        }
        "audio/m4a" | "audio/mp4" | "audio/x-m4a" | "audio/aac" => {
            let _ = hint.with_extension("m4a");
        }
        _ => {}
    }

    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(|e| TranscriptionError::AudioDecode(format!("probe failed: {e}")))?;

    let mut format = probed.format;

    // Find the first audio track
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
        .ok_or_else(|| TranscriptionError::AudioDecode("no audio track found".into()))?;

    let codec_params = track.codec_params.clone();
    let track_id = track.id;
    let source_rate = codec_params.sample_rate.unwrap_or(TARGET_SAMPLE_RATE);
    let channels = codec_params.channels.map_or(1, |c| c.count());

    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &DecoderOptions::default())
        .map_err(|e| TranscriptionError::AudioDecode(format!("codec init failed: {e}")))?;

    let mut all_samples: Vec<f32> = Vec::new();

    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(e) => return Err(TranscriptionError::AudioDecode(format!("packet read: {e}"))),
        };

        if packet.track_id() != track_id {
            continue;
        }

        let decoded = decoder
            .decode(&packet)
            .map_err(|e| TranscriptionError::AudioDecode(format!("decode: {e}")))?;

        let spec = *decoded.spec();
        let n_frames = decoded.capacity();
        let mut sample_buf = SampleBuffer::<f32>::new(n_frames as u64, spec);
        sample_buf.copy_interleaved_ref(decoded);
        let samples = sample_buf.samples();

        // Mix to mono
        if channels > 1 {
            for chunk in samples.chunks(channels) {
                let mono: f32 = chunk.iter().sum::<f32>() / channels as f32;
                all_samples.push(mono);
            }
        } else {
            all_samples.extend_from_slice(samples);
        }
    }

    if all_samples.is_empty() {
        return Err(TranscriptionError::AudioDecode(
            "no audio samples decoded".into(),
        ));
    }

    // Resample if needed
    if source_rate != TARGET_SAMPLE_RATE {
        all_samples = resample(&all_samples, source_rate, TARGET_SAMPLE_RATE)?;
    }

    Ok((all_samples, source_rate))
}

/// Resample mono audio from `from_rate` to `to_rate` using rubato.
fn resample(samples: &[f32], from_rate: u32, to_rate: u32) -> Result<Vec<f32>, TranscriptionError> {
    use rubato::{
        Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
    };

    let params = SincInterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: SincInterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };

    let ratio = f64::from(to_rate) / f64::from(from_rate);
    let chunk_size = 1024;

    let mut resampler = SincFixedIn::<f32>::new(ratio, 2.0, params, chunk_size, 1)
        .map_err(|e| TranscriptionError::Resample(format!("init: {e}")))?;

    let mut output = Vec::with_capacity((samples.len() as f64 * ratio) as usize + 1024);

    for chunk in samples.chunks(chunk_size) {
        let input = if chunk.len() < chunk_size {
            // Pad last chunk with zeros
            let mut padded = chunk.to_vec();
            padded.resize(chunk_size, 0.0);
            vec![padded]
        } else {
            vec![chunk.to_vec()]
        };

        let resampled = resampler
            .process(&input, None)
            .map_err(|e| TranscriptionError::Resample(format!("process: {e}")))?;

        if let Some(channel) = resampled.first() {
            output.extend_from_slice(channel);
        }
    }

    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_invalid_audio_returns_error() {
        let result = decode_audio(b"not audio data", "audio/wav");
        assert!(result.is_err());
    }

    #[test]
    fn decode_empty_returns_error() {
        let result = decode_audio(b"", "audio/wav");
        assert!(result.is_err());
    }

    #[test]
    fn resample_identity() {
        // Resampling from 16kHz to 16kHz should be approximately identity
        let samples: Vec<f32> = (0..16000).map(|i| (i as f32 / 16000.0).sin()).collect();
        let result = resample(&samples, 16000, 16000).unwrap();
        // Should have approximately the same number of samples
        let ratio = result.len() as f64 / samples.len() as f64;
        assert!((ratio - 1.0).abs() < 0.1, "ratio: {ratio}");
    }

    #[test]
    fn resample_downsample() {
        // 48kHz → 16kHz should produce ~1/3 the samples
        let samples: Vec<f32> = (0..48000).map(|i| (i as f32 / 48000.0).sin()).collect();
        let result = resample(&samples, 48000, 16000).unwrap();
        let ratio = result.len() as f64 / samples.len() as f64;
        assert!((ratio - 1.0 / 3.0).abs() < 0.05, "ratio: {ratio}");
    }

    #[test]
    fn decode_wav_synthetic() {
        // Generate a minimal valid WAV file (16kHz mono 16-bit, 0.1s of silence)
        let wav = generate_test_wav(16000, 1, 1600);
        let (samples, _rate) = decode_audio(&wav, "audio/wav").unwrap();
        assert!(!samples.is_empty());
        assert!(samples.iter().all(|&s| s >= -1.0 && s <= 1.0));
    }

    #[test]
    fn decode_wav_44khz_resamples_to_16khz() {
        // Generate 44.1kHz stereo WAV, 0.5s
        let wav = generate_test_wav(44100, 2, 22050);
        let (samples, _) = decode_audio(&wav, "audio/wav").unwrap();
        assert!(!samples.is_empty());
        // Should have been resampled to ~16kHz
        // 0.5s at 16kHz ≈ 8000 samples (mono output)
        let expected_approx = 8000;
        let ratio = samples.len() as f64 / expected_approx as f64;
        assert!(
            (ratio - 1.0).abs() < 0.2,
            "Expected ~{expected_approx} samples, got {}: ratio {ratio}",
            samples.len()
        );
    }

    /// Generate a minimal valid WAV file for testing.
    fn generate_test_wav(sample_rate: u32, channels: u16, num_samples: u32) -> Vec<u8> {
        let bits_per_sample: u16 = 16;
        let byte_rate = sample_rate * u32::from(channels) * u32::from(bits_per_sample) / 8;
        let block_align = channels * bits_per_sample / 8;
        let data_size = num_samples * u32::from(channels) * u32::from(bits_per_sample) / 8;
        let file_size = 36 + data_size;

        let mut buf = Vec::with_capacity(file_size as usize + 8);
        // RIFF header
        buf.extend_from_slice(b"RIFF");
        buf.extend_from_slice(&file_size.to_le_bytes());
        buf.extend_from_slice(b"WAVE");
        // fmt chunk
        buf.extend_from_slice(b"fmt ");
        buf.extend_from_slice(&16u32.to_le_bytes()); // chunk size
        buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
        buf.extend_from_slice(&channels.to_le_bytes());
        buf.extend_from_slice(&sample_rate.to_le_bytes());
        buf.extend_from_slice(&byte_rate.to_le_bytes());
        buf.extend_from_slice(&block_align.to_le_bytes());
        buf.extend_from_slice(&bits_per_sample.to_le_bytes());
        // data chunk
        buf.extend_from_slice(b"data");
        buf.extend_from_slice(&data_size.to_le_bytes());
        // Silent samples (zeros)
        buf.resize(buf.len() + data_size as usize, 0);
        buf
    }
}

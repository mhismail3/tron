//! TDT greedy decoding loop for the `parakeet-tdt` model.
//!
//! ONNX tensor shapes use `i64` dimensions while Rust indexing needs `usize`.
//! These casts are safe because tensor dimensions are always small positive values.

use ndarray::{Array2, Array3};
use ort::session::Session;
use ort::value::Tensor;
use tracing::debug;

use crate::types::{ResultExt, TranscriptionError};

/// TDT duration buckets: how many encoder frames to advance per step.
pub const DURATIONS: [usize; 5] = [0, 1, 2, 3, 4];

/// Hidden state dimension for the LSTM decoder.
const LSTM_STATE_DIM: usize = 640;

/// Safety multiplier — decode loop terminates after `time_steps * MAX_STEPS_MULTIPLIER` iterations.
const MAX_STEPS_MULTIPLIER: usize = 5;

/// Greedy TDT decoding: walk encoder output frame-by-frame using the `decoder_joint` network.
///
/// The `decoder_joint` model takes encoder frames + previous token + LSTM states,
/// and outputs token logits + duration logits. The token with highest logit is
/// emitted (if not blank), and we advance by the predicted duration.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
pub fn greedy_decode(
    encoder_out: &Array2<f32>,
    decoder_joint: &mut Session,
    vocab: &[String],
    blank_idx: usize,
) -> Result<String, TranscriptionError> {
    let time_steps = encoder_out.shape()[0];
    let hidden_dim = encoder_out.shape()[1]; // 1024

    let mut step: usize = 0;
    let mut tokens: Vec<usize> = Vec::new();
    let mut prev_token = blank_idx;

    // Pre-allocate reusable LSTM state buffers (avoids per-iteration allocation)
    let mut state1_data = vec![0.0f32; LSTM_STATE_DIM];
    let mut state2_data = vec![0.0f32; LSTM_STATE_DIM];

    let max_steps = time_steps * MAX_STEPS_MULTIPLIER;
    let mut total_steps = 0;

    while step < time_steps {
        total_steps += 1;
        if total_steps > max_steps {
            debug!("TDT decode hit step limit at frame {step}/{time_steps}");
            break;
        }

        // Encoder frame: [1, 1, hidden_dim]
        let frame: Vec<f32> = encoder_out.row(step).to_vec();
        let encoder_input = Tensor::from_array(([1i64, 1, hidden_dim as i64], frame))
            .inference("encoder frame tensor")?;

        // Target token: [1, 1]
        let target = Tensor::from_array(([1i64, 1], vec![prev_token as i64]))
            .inference("target tensor")?;
        let target_length =
            Tensor::from_array(([1i64], vec![1i64])).inference("target_length tensor")?;

        // LSTM states: [1, 1, 640]
        let s1 =
            Tensor::from_array(([1i64, 1, LSTM_STATE_DIM as i64], state1_data.clone()))
                .inference("state1 tensor")?;
        let s2 =
            Tensor::from_array(([1i64, 1, LSTM_STATE_DIM as i64], state2_data.clone()))
                .inference("state2 tensor")?;

        let outputs = decoder_joint
            .run(ort::inputs![
                "encoder_outputs" => encoder_input,
                "targets" => target,
                "target_length" => target_length,
                "input_states_1" => s1,
                "input_states_2" => s2,
            ])
            .inference("decoder_joint run")?;

        // Extract outputs — ort 2.0 returns (&Shape, &[T])
        let (_, logits) = outputs["outputs"]
            .try_extract_tensor::<f32>()
            .inference("extract logits")?;

        // Update LSTM states in-place (avoids allocation via .to_vec())
        let (_, s1_out) = outputs["output_states_1"]
            .try_extract_tensor::<f32>()
            .inference("extract state1")?;
        state1_data.copy_from_slice(s1_out);

        let (_, s2_out) = outputs["output_states_2"]
            .try_extract_tensor::<f32>()
            .inference("extract state2")?;
        state2_data.copy_from_slice(s2_out);

        // Split logits into token logits and duration logits
        let vocab_size = vocab.len();
        if logits.len() < vocab_size + DURATIONS.len() {
            return Err(TranscriptionError::Inference(format!(
                "logits too short: {} < {} + {}",
                logits.len(),
                vocab_size,
                DURATIONS.len()
            )));
        }

        let token_logits = &logits[..vocab_size];
        let duration_logits = &logits[vocab_size..vocab_size + DURATIONS.len()];

        // Argmax for token and duration
        let token = argmax(token_logits);
        let duration_idx = argmax(duration_logits);
        let advance = DURATIONS[duration_idx];

        if token != blank_idx {
            tokens.push(token);
            prev_token = token;
        }

        let prev_step = step;
        step += advance;
        // Anti-stuck: if duration predicted 0, advance by 1
        if step == prev_step {
            step += 1;
        }
    }

    // Convert token IDs to text
    let text: String = tokens
        .iter()
        .filter_map(|&t| vocab.get(t).map(String::as_str))
        .collect::<String>()
        .replace('\u{2581}', " ") // SentencePiece ▁ → space
        .trim()
        .to_string();

    debug!(
        "decoded {} tokens from {} frames → {} chars",
        tokens.len(),
        time_steps,
        text.len()
    );

    Ok(text)
}

/// Find the index of the maximum value in a slice.
fn argmax(slice: &[f32]) -> usize {
    slice
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
        .map_or(0, |(i, _)| i)
}

/// Run the encoder model on mel features.
///
/// Input: mel features `[1, 128, T]` from preprocessor
/// Output: encoder output `[T', hidden_dim]` (squeezed from `[1, T', hidden_dim]`)
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
pub fn run_encoder(
    encoder: &mut Session,
    features: &Array3<f32>,
    features_len: i64,
) -> Result<(Array2<f32>, i64), TranscriptionError> {
    let shape = features.shape();
    let flat: Vec<f32> = features.iter().copied().collect();
    let audio_signal =
        Tensor::from_array(([shape[0] as i64, shape[1] as i64, shape[2] as i64], flat))
            .inference("encoder audio_signal tensor")?;
    let length = Tensor::from_array(([1i64], vec![features_len]))
        .inference("encoder length tensor")?;

    let outputs = encoder
        .run(ort::inputs![
            "audio_signal" => audio_signal,
            "length" => length,
        ])
        .inference("encoder run")?;

    let (enc_shape, enc_data) = outputs["outputs"]
        .try_extract_tensor::<f32>()
        .inference("extract encoder output")?;

    let (_, enc_len_data) = outputs["encoded_lengths"]
        .try_extract_tensor::<i64>()
        .inference("extract encoded_lengths")?;
    let enc_len = enc_len_data[0];

    // Squeeze batch dim: [1, T', H] → [T', H]
    let t_prime = enc_shape[1] as usize;
    let hidden = enc_shape[2] as usize;

    let out = Array2::from_shape_vec((t_prime, hidden), enc_data.to_vec())
        .inference("reshape encoder")?;

    Ok((out, enc_len))
}

/// Run the mel preprocessor on raw waveform samples.
///
/// Input: waveform [1, N] (16kHz mono f32)
/// Output: mel features [1, 128, T]
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
pub fn run_preprocessor(
    preprocessor: &mut Session,
    samples: &[f32],
) -> Result<(Array3<f32>, i64), TranscriptionError> {
    let n = samples.len();
    let waveform = Tensor::from_array(([1i64, n as i64], samples.to_vec()))
        .inference("waveform tensor")?;

    let waveform_lens = Tensor::from_array(([1i64], vec![n as i64]))
        .inference("waveform_lens tensor")?;

    let outputs = preprocessor
        .run(ort::inputs![
            "waveforms" => waveform,
            "waveforms_lens" => waveform_lens,
        ])
        .inference("preprocessor run")?;

    let (feat_shape, feat_data) = outputs["features"]
        .try_extract_tensor::<f32>()
        .inference("extract features")?;

    let (_, feat_len_data) = outputs["features_lens"]
        .try_extract_tensor::<i64>()
        .inference("extract features_lens")?;
    let feat_len = feat_len_data[0];

    // Clone into Array3 [1, 128, T]
    let out = Array3::from_shape_vec(
        (
            feat_shape[0] as usize,
            feat_shape[1] as usize,
            feat_shape[2] as usize,
        ),
        feat_data.to_vec(),
    )
    .inference("reshape features")?;

    Ok((out, feat_len))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tdt_durations_constant() {
        assert_eq!(DURATIONS, [0, 1, 2, 3, 4]);
    }

    #[test]
    fn lstm_state_dim_constant() {
        assert_eq!(LSTM_STATE_DIM, 640);
    }

    #[test]
    fn max_steps_multiplier_constant() {
        assert_eq!(MAX_STEPS_MULTIPLIER, 5);
    }

    #[test]
    fn argmax_basic() {
        assert_eq!(argmax(&[1.0, 3.0, 2.0]), 1);
        assert_eq!(argmax(&[5.0, 1.0, 2.0]), 0);
        assert_eq!(argmax(&[0.0, 0.0, 1.0]), 2);
    }

    #[test]
    fn argmax_single() {
        assert_eq!(argmax(&[42.0]), 0);
    }

    #[test]
    fn argmax_negative() {
        assert_eq!(argmax(&[-3.0, -1.0, -2.0]), 1);
    }

    #[test]
    fn argmax_all_equal() {
        // max_by returns the last maximum element when equal
        assert_eq!(argmax(&[1.0, 1.0, 1.0]), 2);
    }

    #[test]
    fn sentencepiece_replacement() {
        // Verify the ▁ → space replacement logic
        let text = "▁Hello▁world".replace('\u{2581}', " ").trim().to_string();
        assert_eq!(text, "Hello world");
    }
}

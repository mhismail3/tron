from __future__ import annotations

import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, Optional

from faster_whisper import WhisperModel
from faster_whisper.audio import decode_audio

from .cleanup import apply_cleanup
from .config import TranscribeConfig, ensure_dirs, load_config

_CONFIG = load_config()
_MODEL: Optional[WhisperModel] = None


def get_config() -> TranscribeConfig:
    return _CONFIG


def _load_model() -> WhisperModel:
    global _MODEL
    if _MODEL is None:
        ensure_dirs(_CONFIG)
        _MODEL = WhisperModel(
            _CONFIG.model_name,
            device=_CONFIG.device,
            compute_type=_CONFIG.compute_type,
            download_root=str(_CONFIG.models_dir),
            cpu_threads=_CONFIG.cpu_threads,
            num_workers=_CONFIG.num_workers,
        )
    return _MODEL


def transcribe_file(
    audio_path: Path,
    *,
    language: Optional[str] = None,
    task: Optional[str] = None,
    prompt: Optional[str] = None,
    cleanup_mode: Optional[str] = None,
    return_segments: bool = False,
) -> dict[str, Any]:
    config = _CONFIG
    model = _load_model()

    audio = decode_audio(str(audio_path), sampling_rate=16000)
    duration_s = len(audio) / 16000.0
    if duration_s > config.max_duration_s:
        raise ValueError(f"Audio exceeds max duration ({config.max_duration_s}s)")

    start = time.monotonic()
    segments, info = model.transcribe(
        audio,
        language=language or config.language,
        task=task or "transcribe",
        beam_size=config.beam_size,
        vad_filter=config.vad_filter,
        word_timestamps=config.word_timestamps,
        temperature=config.temperature,
        initial_prompt=prompt,
    )

    collected_segments = []
    text_parts = []
    for segment in segments:
        text_parts.append(segment.text)
        if return_segments:
            collected_segments.append({
                "start": float(segment.start),
                "end": float(segment.end),
                "text": segment.text.strip(),
            })

    raw_text = "".join(text_parts).strip()
    cleaned_text = apply_cleanup(raw_text, config, cleanup_mode)
    elapsed_ms = int((time.monotonic() - start) * 1000)

    result: dict[str, Any] = {
        "text": cleaned_text,
        "raw_text": raw_text,
        "language": info.language,
        "duration_s": round(duration_s, 3),
        "processing_time_ms": elapsed_ms,
        "model": config.model_name,
        "compute_type": config.compute_type,
        "device": config.device,
        "cleanup_mode": cleanup_mode or config.cleanup_mode,
        "config": {
            "beam_size": config.beam_size,
            "vad_filter": config.vad_filter,
            "word_timestamps": config.word_timestamps,
            "temperature": config.temperature,
        },
    }

    if return_segments:
        result["segments"] = collected_segments

    return result


def describe_config() -> dict[str, Any]:
    config = _CONFIG
    data = asdict(config)
    data["base_dir"] = str(config.base_dir)
    data["models_dir"] = str(config.models_dir)
    data["tmp_dir"] = str(config.tmp_dir)
    data["logs_dir"] = str(config.logs_dir)
    if config.cleanup_llm_api_key:
        data["cleanup_llm_api_key"] = "set"
    return data

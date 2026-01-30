from __future__ import annotations

import threading
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, Optional
import inspect
import subprocess
import uuid
import wave

from .cleanup import apply_cleanup
from .config import TranscribeConfig, ensure_dirs, load_config

_CONFIG = load_config()
_MODEL_CACHE: dict[tuple[str, str, str, str], object] = {}
_MODEL_CACHE_LOCK = threading.Lock()


def get_config() -> TranscribeConfig:
    return _CONFIG


def _load_model(
    backend: str,
    model_name: str,
    device: str,
    compute_type: str,
    config: TranscribeConfig,
) -> Optional[object]:
    """Load a transcription model, with thread-safe caching.

    Uses double-checked locking to avoid loading the same model twice
    when multiple threads request it simultaneously.
    """
    key = (backend, model_name, device, compute_type)

    # Fast path: check cache without lock
    if key in _MODEL_CACHE:
        return _MODEL_CACHE[key]

    # Slow path: acquire lock and check again before loading
    with _MODEL_CACHE_LOCK:
        # Double-check after acquiring lock (another thread may have loaded it)
        if key in _MODEL_CACHE:
            return _MODEL_CACHE[key]

        ensure_dirs(config)

        if backend == "parakeet-mlx":
            try:
                from parakeet_mlx import from_pretrained
            except ImportError as error:
                raise RuntimeError(
                    "parakeet-mlx is not installed. Run `pip install parakeet-mlx` in services/transcribe/.venv."
                ) from error
            model = from_pretrained(model_name)
            _MODEL_CACHE[key] = model
            return model

        raise RuntimeError(f"Unsupported transcription backend: {backend}")


def transcribe_file(
    audio_path: Path,
    *,
    backend: Optional[str] = None,
    model_name: Optional[str] = None,
    device: Optional[str] = None,
    compute_type: Optional[str] = None,
    language: Optional[str] = None,
    task: Optional[str] = None,
    prompt: Optional[str] = None,
    cleanup_mode: Optional[str] = None,
    return_segments: bool = False,
) -> dict[str, Any]:
    config = _CONFIG

    # Use config defaults, with optional overrides
    effective_backend = (backend or config.backend).lower()
    effective_model = model_name or config.model_name
    effective_device = device or config.device
    effective_compute = compute_type or config.compute_type

    model = _load_model(
        effective_backend,
        effective_model,
        effective_device,
        effective_compute,
        config,
    )

    segments = None
    detected_language = None
    raw_text = ""
    duration_s = 0.0
    elapsed_ms = 0

    wav_path, converted_path = _convert_to_wav(audio_path, config)
    try:
        duration_s = _wav_duration_seconds(wav_path)
        if duration_s > config.max_duration_s:
            raise ValueError(f"Audio exceeds max duration ({config.max_duration_s}s)")

        start = time.monotonic()
        raw_result = _run_transcription(
            effective_backend,
            model,
            wav_path,
            language=language or config.language,
            task=task,
            prompt=prompt,
        )
        raw_text, detected_language, segments = _extract_transcript(raw_result)
        raw_text = raw_text.strip()
        elapsed_ms = int((time.monotonic() - start) * 1000)
    finally:
        if converted_path is not None:
            try:
                converted_path.unlink(missing_ok=True)
            except OSError:
                pass

    cleaned_text = apply_cleanup(raw_text, config, cleanup_mode)

    result: dict[str, Any] = {
        "text": cleaned_text,
        "raw_text": raw_text,
        "language": detected_language or (language or config.language),
        "duration_s": round(duration_s, 3),
        "processing_time_ms": elapsed_ms,
        "model": effective_model,
        "compute_type": effective_compute,
        "device": effective_device,
        "cleanup_mode": cleanup_mode or config.cleanup_mode,
        "backend": effective_backend,
        "config": {
            "beam_size": config.beam_size,
            "vad_filter": config.vad_filter,
            "word_timestamps": config.word_timestamps,
            "temperature": config.temperature,
        },
    }

    if return_segments:
        result["segments"] = _normalize_segments(segments)

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


def _convert_to_wav(audio_path: Path, config: TranscribeConfig) -> tuple[Path, Optional[Path]]:
    if audio_path.suffix.lower() == ".wav":
        return audio_path, None

    ensure_dirs(config)
    wav_path = config.tmp_dir / f"{audio_path.stem}-{uuid.uuid4().hex}.wav"
    command = [
        "ffmpeg",
        "-y",
        "-i",
        str(audio_path),
        "-ac",
        "1",
        "-ar",
        "16000",
        str(wav_path),
    ]
    try:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError as error:
        raise RuntimeError("ffmpeg is required to decode audio input but was not found in PATH.") from error
    except subprocess.CalledProcessError as error:
        stderr = error.stderr.decode("utf-8", errors="ignore").strip()
        detail = stderr.splitlines()[-1] if stderr else "ffmpeg failed"
        raise RuntimeError(f"Audio conversion failed: {detail}") from error
    return wav_path, wav_path


def _wav_duration_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
    if rate == 0:
        raise ValueError("Audio sample rate is 0")
    return frames / float(rate)


def _run_transcription(
    backend: str,
    model: object,
    audio_path: Path,
    *,
    language: Optional[str],
    task: Optional[str],
    prompt: Optional[str],
) -> Any:
    if backend == "parakeet-mlx":
        transcribe = getattr(model, "transcribe", None)
        if not callable(transcribe):
            raise RuntimeError("Parakeet model does not expose a transcribe() method")
        return _call_transcribe(transcribe, audio_path, language=language, task=task, prompt=prompt)

    raise RuntimeError(f"Unsupported transcription backend: {backend}")


def _call_transcribe(
    transcribe: Any,
    audio_path: Path,
    *,
    language: Optional[str],
    task: Optional[str],
    prompt: Optional[str],
) -> Any:
    kwargs: dict[str, Any] = {}
    signature = _safe_signature(transcribe)
    if signature is not None:
        if language and "language" in signature.parameters:
            kwargs["language"] = language
        if task and "task" in signature.parameters:
            kwargs["task"] = task
        if prompt and "prompt" in signature.parameters:
            kwargs["prompt"] = prompt

    return transcribe(str(audio_path), **kwargs)


def _extract_transcript(result: Any) -> tuple[str, Optional[str], Any]:
    if isinstance(result, str):
        return result, None, None

    if isinstance(result, dict):
        text = result.get("text") or result.get("transcript") or result.get("utterance")
        language = result.get("language") or result.get("lang")
        segments = result.get("segments") or result.get("timestamps") or result.get("chunks")
        if text:
            return str(text), str(language) if language else None, segments

    text = getattr(result, "text", None) or getattr(result, "transcript", None)
    if text:
        language = getattr(result, "language", None) or getattr(result, "lang", None)
        segments = getattr(result, "segments", None) or getattr(result, "timestamps", None)
        return str(text), str(language) if language else None, segments

    raise ValueError("Transcription model returned no text")


def _normalize_segments(segments: Any) -> list[dict[str, Any]]:
    if not segments:
        return []
    normalized: list[dict[str, Any]] = []
    if isinstance(segments, list):
        for segment in segments:
            if isinstance(segment, dict):
                text = segment.get("text") or segment.get("transcript")
                start = segment.get("start")
                end = segment.get("end")
            elif isinstance(segment, (list, tuple)) and len(segment) >= 3:
                start, end, text = segment[0], segment[1], segment[2]
            else:
                continue
            if text is None:
                continue
            normalized.append({
                "start": float(start) if start is not None else 0.0,
                "end": float(end) if end is not None else 0.0,
                "text": str(text).strip(),
            })
    return normalized


def _safe_signature(callable_obj: Any) -> Optional[inspect.Signature]:
    try:
        return inspect.signature(callable_obj)
    except (TypeError, ValueError):
        return None

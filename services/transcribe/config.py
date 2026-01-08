from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

DEFAULT_BASE_DIR = Path("~/.tron/transcribe").expanduser()
DEFAULT_CONFIG_PATH = DEFAULT_BASE_DIR / "config.json"


def _to_bool(value: Any, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "y", "on"}:
        return True
    if text in {"0", "false", "no", "n", "off"}:
        return False
    return default


def _to_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _to_float(value: Any, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class TranscribeConfig:
    base_dir: Path
    models_dir: Path
    tmp_dir: Path
    logs_dir: Path

    host: str
    port: int

    model_name: str
    device: str
    compute_type: str
    language: str
    beam_size: int
    vad_filter: bool
    word_timestamps: bool
    temperature: float
    max_duration_s: int
    cpu_threads: int
    num_workers: int

    cleanup_mode: str
    cleanup_llm_base_url: str
    cleanup_llm_model: str
    cleanup_llm_api_key: Optional[str]


def load_config() -> TranscribeConfig:
    file_path = Path(os.environ.get("TRON_TRANSCRIBE_CONFIG", DEFAULT_CONFIG_PATH)).expanduser()
    file_data: dict[str, Any] = {}
    if file_path.is_file():
        try:
            file_data = json.loads(file_path.read_text())
        except (OSError, json.JSONDecodeError):
            file_data = {}

    def pick(key: str, default: Any) -> Any:
        if key in os.environ:
            return os.environ[key]
        return file_data.get(key, default)

    base_dir = Path(pick("base_dir", DEFAULT_BASE_DIR)).expanduser()
    models_dir = Path(pick("models_dir", base_dir / "models")).expanduser()
    tmp_dir = Path(pick("tmp_dir", base_dir / "tmp")).expanduser()
    logs_dir = Path(pick("logs_dir", base_dir / "logs")).expanduser()

    host = str(pick("host", "127.0.0.1"))
    port = _to_int(pick("port", 8787), 8787)

    model_name = str(pick("model_name", "large-v3"))
    device = str(pick("device", "cpu"))
    compute_type = str(pick("compute_type", "int8"))
    language = str(pick("language", "en"))
    beam_size = _to_int(pick("beam_size", 5), 5)
    vad_filter = _to_bool(pick("vad_filter", True), True)
    word_timestamps = _to_bool(pick("word_timestamps", False), False)
    temperature = _to_float(pick("temperature", 0.0), 0.0)
    max_duration_s = _to_int(pick("max_duration_s", 120), 120)
    cpu_threads = _to_int(pick("cpu_threads", 0), 0)
    num_workers = _to_int(pick("num_workers", 1), 1)

    cleanup_mode = str(pick("cleanup_mode", "basic"))
    cleanup_llm_base_url = str(pick("cleanup_llm_base_url", "http://127.0.0.1:11434/v1"))
    cleanup_llm_model = str(pick("cleanup_llm_model", "llama3.1:8b"))
    cleanup_llm_api_key = os.environ.get("TRON_TRANSCRIBE_LLM_API_KEY") or file_data.get("cleanup_llm_api_key")

    return TranscribeConfig(
        base_dir=base_dir,
        models_dir=models_dir,
        tmp_dir=tmp_dir,
        logs_dir=logs_dir,
        host=host,
        port=port,
        model_name=model_name,
        device=device,
        compute_type=compute_type,
        language=language,
        beam_size=beam_size,
        vad_filter=vad_filter,
        word_timestamps=word_timestamps,
        temperature=temperature,
        max_duration_s=max_duration_s,
        cpu_threads=cpu_threads,
        num_workers=num_workers,
        cleanup_mode=cleanup_mode,
        cleanup_llm_base_url=cleanup_llm_base_url,
        cleanup_llm_model=cleanup_llm_model,
        cleanup_llm_api_key=cleanup_llm_api_key,
    )


def ensure_dirs(config: TranscribeConfig) -> None:
    config.base_dir.mkdir(parents=True, exist_ok=True)
    config.models_dir.mkdir(parents=True, exist_ok=True)
    config.tmp_dir.mkdir(parents=True, exist_ok=True)
    config.logs_dir.mkdir(parents=True, exist_ok=True)

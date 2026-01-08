# Transcription Sidecar (faster-whisper)

Internal transcription service used by the Tron server. The server auto-starts
this sidecar when `server.transcription.manageSidecar` is true and the
transcription `baseUrl` points to localhost.

## Requirements

- Python 3.11+
- `ffmpeg` (required for decoding m4a and other compressed formats)

Install ffmpeg on macOS:

```bash
brew install ffmpeg
```

## Auto-managed startup

On first start, the Tron server creates a venv in `services/transcribe/.venv`
and installs dependencies from `services/transcribe/requirements.txt`.

Override the Python binary with:

```
TRON_PYTHON=/path/to/python3
```

If the server cannot locate the repo root, set:

```
TRON_REPO_ROOT=/path/to/tron
```

## Configuration

The service reads config from `~/.tron/transcribe/config.json` by default.
Set `TRON_TRANSCRIBE_CONFIG` to point elsewhere.

Example `config.json`:

```json
{
  "model_name": "large-v3",
  "device": "cpu",
  "compute_type": "int8",
  "language": "en",
  "beam_size": 5,
  "vad_filter": true,
  "word_timestamps": false,
  "temperature": 0.0,
  "max_duration_s": 120,
  "cleanup_mode": "basic",
  "cleanup_llm_base_url": "http://127.0.0.1:11434/v1",
  "cleanup_llm_model": "llama3.1:8b"
}
```

Notes:
- Model downloads go to `~/.tron/transcribe/models`.
- `cleanup_mode` supports `none`, `basic`, or `llm`.
- `int8` is the default since CPU-only `float16` is not supported by faster-whisper.

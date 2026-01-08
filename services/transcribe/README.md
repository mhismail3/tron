# Transcription Sidecar (parakeet-mlx / mlx-whisper)

Internal transcription service used by the Tron server. The server auto-starts
this sidecar when `server.transcription.manageSidecar` is true and the
transcription `baseUrl` points to localhost.

## Requirements

- Python 3.11+
- `ffmpeg` (required for decoding m4a and other compressed formats)
- Apple Silicon recommended (parakeet-mlx uses MLX)

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

Quickly write a config file:

```bash
./services/transcribe/write-config.sh
```

Endpoints:
- `POST /transcribe` (generic, supports backend overrides)
- `POST /transcribe/faster` (Parakeet MLX)
- `POST /transcribe/better` (faster-whisper)

Example `config.json`:

```json
{
  "backend": "parakeet-mlx",
  "model_name": "mlx-community/parakeet-tdt-0.6b-v3",
  "device": "mlx",
  "compute_type": "mlx",
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

To switch to mlx-whisper:

```json
{
  "backend": "mlx-whisper",
  "model_name": "mlx-community/whisper-large-v3-turbo",
  "device": "mlx",
  "compute_type": "mlx"
}
```

To switch to faster-whisper:

```json
{
  "backend": "faster-whisper",
  "model_name": "large-v3",
  "device": "cpu",
  "compute_type": "int8"
}
```

Notes:
- Model downloads go to `~/.tron/transcribe/models`.
- `cleanup_mode` supports `none`, `basic`, or `llm`.
- Whisper-style settings like `beam_size` are ignored by parakeet-mlx.

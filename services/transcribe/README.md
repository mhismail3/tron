# Transcribe Sidecar (faster-whisper)

Local transcription service for manual testing before Tron server/iOS integration.

## Requirements

- Python 3.11+ (onnxruntime does not yet ship wheels for Python 3.14)
- `ffmpeg` (used to decode audio formats)

Install ffmpeg (macOS):

```bash
brew install ffmpeg
```

## Setup (venv)

```bash
services/transcribe/setup.sh
services/transcribe/write-config.sh
```

## Run the server

```bash
services/transcribe/run.sh
```

The server binds to `127.0.0.1:8787` by default.

## Manual test (HTTP)

```bash
curl -s \
  -F "audio=@/path/to/audio.m4a" \
  -F "cleanup_mode=basic" \
  http://127.0.0.1:8787/transcribe
```

To include segments:

```bash
curl -s \
  -F "audio=@/path/to/audio.m4a" \
  -F "return_segments=true" \
  http://127.0.0.1:8787/transcribe
```

## Manual test (CLI)

```bash
PYTHONPATH=. services/transcribe/.venv/bin/python -m services.transcribe.transcribe_cli /path/to/audio.m4a
```

## Config

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
  "cleanup_mode": "llm",
  "cleanup_llm_base_url": "http://127.0.0.1:11434/v1",
  "cleanup_llm_model": "llama3.1:8b"
}
```

Notes:
- Model downloads go to `~/.tron/transcribe/models`.
- First run of `large-v3` will download multiple GB and can take a while.
- `cleanup_mode` supports `none`, `basic`, or `llm`.
  - `basic` does simple whitespace/punctuation cleanup.
  - `llm` calls an OpenAI-compatible endpoint (default points to local Ollama).
  - Set `TRON_TRANSCRIBE_LLM_API_KEY` if your endpoint requires a key.
- `int8` is the default since CPU-only `float16` is not supported by faster-whisper.
- If you want higher accuracy on CPU and can accept slower speed, try `compute_type: "float32"`.

## Local LLM cleanup (Ollama)

Install and start Ollama:

```bash
brew install ollama
ollama serve
```

Pull the cleanup model:

```bash
ollama pull llama3.1:8b
```

Keep `ollama serve` running in a separate terminal, then run the transcribe service with `cleanup_mode=llm`.
If you don't want LLM cleanup, set `cleanup_mode` to `basic` in `config.json`.

## Recording a quick sample (optional)

```bash
ffmpeg -f avfoundation -i ":0" -t 10 /tmp/tron-sample.m4a
```

Then run:

```bash
curl -s -F "audio=@/tmp/tron-sample.m4a" http://127.0.0.1:8787/transcribe
```

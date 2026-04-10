# Local LLM Setup: Ollama + Gemma 4

Validated on 2026-04-10. Machine: M4 Pro MacBook Pro, 24GB unified memory.

## Installation

```bash
brew install ollama          # Installs Ollama + dependencies (mlx, mlx-c, python@3.14)
brew services start ollama   # Start as background service (auto-starts on login)
```

Installed version: **Ollama 0.20.5** (via Homebrew).
Minimum required: **0.20.3** (tool calling bug fix from April 7, 2026).

### Verify

```bash
ollama --version                          # Should show >= 0.20.3
curl -s http://localhost:11434/api/version # Should return {"version":"0.20.5"}
```

## Model: Gemma 4 E4B (Validation)

```bash
ollama pull gemma4:e4b    # ~9.6 GB download
ollama list               # Verify model appears
ollama show gemma4:e4b    # Show model details
```

### Model Details (from `ollama show`)

| Property | Value |
|----------|-------|
| Architecture | gemma4 |
| Parameters | 8.0B (4.5B effective, dense) |
| Quantization | Q4_K_M (4-bit) |
| Context length | 131,072 tokens (128K) |
| Size on disk | 9.6 GB |
| Capabilities | completion, vision, audio, tools, thinking |
| Min Ollama version | 0.20.0 |

### Production Model: Gemma 4 26B MoE

Not yet validated (requires M5 Max 36GB). Pull with:

```bash
ollama pull gemma4:26b    # ~18 GB download
```

Key differences from E4B:
- 26B total params, 3.8B active per token (Mixture of Experts)
- 256K context window (2x the E4B)
- Significantly higher quality (reasoning, code, tool selection)
- Needs ~18GB+ RAM (tight on 24GB, comfortable on 36GB)

## API Endpoints

Ollama serves on `http://localhost:11434`. Two API styles available:

### OpenAI-Compatible (preferred for Tron integration)

| Endpoint | Purpose |
|----------|---------|
| `GET /v1/models` | List available models |
| `POST /v1/chat/completions` | Chat completions (streaming + non-streaming) |

### Ollama Native

| Endpoint | Purpose |
|----------|---------|
| `GET /api/version` | Server version |
| `POST /api/chat` | Chat (Ollama format) |
| `POST /api/generate` | Raw generation |

### Example: Non-Streaming Chat Completion

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4:e4b",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false
  }'
```

Response format:
```json
{
  "id": "chatcmpl-60",
  "object": "chat.completion",
  "created": 1775808035,
  "model": "gemma4:e4b",
  "system_fingerprint": "fp_ollama",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Hello! How can I help?",
      "reasoning": "...thinking process..."
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 31,
    "completion_tokens": 805,
    "total_tokens": 836
  }
}
```

### Example: Streaming

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4:e4b",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

Streaming format: SSE with `data:` prefixed JSON chunks. Terminates with `data: [DONE]`.

Each chunk:
```json
{"id":"chatcmpl-947","object":"chat.completion.chunk","created":1775808043,"model":"gemma4:e4b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}
```

Final chunk has `"finish_reason":"stop"` (or `"tool_calls"`).

## Tool Calling

**Status: WORKING** on Ollama 0.20.5 with Gemma 4 E4B.

### Non-Streaming Tool Call

Request with tools defined:
```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4:e4b",
    "messages": [
      {"role": "user", "content": "What is the weather in San Francisco?"}
    ],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City and state"}
          },
          "required": ["location"]
        }
      }
    }]
  }'
```

Response:
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "",
      "reasoning": "...model's thinking about tool selection...",
      "tool_calls": [{
        "id": "call_59hwic94",
        "index": 0,
        "type": "function",
        "function": {
          "name": "get_weather",
          "arguments": "{\"location\":\"San Francisco\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

### Streaming Tool Call

Tool calls arrive as a single chunk near the end of the stream:
```json
{"choices":[{"delta":{"tool_calls":[{"id":"call_hvxazfyz","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"location\":\"San Francisco\"}"}}]},"finish_reason":null}]}
```

Followed by `"finish_reason":"tool_calls"` then `[DONE]`.

### Tool Result Round-Trip

Feed tool results back with `role: "tool"` and matching `tool_call_id`:
```json
{
  "messages": [
    {"role": "user", "content": "Search for config.json files"},
    {"role": "assistant", "content": "", "tool_calls": [{"id": "call_abc123", "type": "function", "function": {"name": "search_files", "arguments": "{\"pattern\": \"config.json\"}"}}]},
    {"role": "tool", "tool_call_id": "call_abc123", "content": "Found: /src/config.json, /tests/config.json"}
  ]
}
```

The model correctly synthesizes tool results into natural language responses.

### Key Observations

- `finish_reason` is `"tool_calls"` when the model wants to call a tool, `"stop"` otherwise
- Tool call IDs follow format `call_XXXXXXXX` (8 random alphanumeric chars)
- `reasoning` field always present (contains model's thinking about tool selection)
- Multiple tools can be defined; model picks the appropriate one
- Model correctly handles the full cycle: user message -> tool call -> tool result -> assistant response

## System Prompt Limits

**Reported bug**: 26B MoE returns empty responses with system prompts >500 chars.

**Tested on E4B (v0.20.5)**:

| System Prompt Size | Result | Tool Calling |
|-------------------|--------|--------------|
| ~200 chars | OK | n/a |
| ~600 chars | OK | n/a |
| ~1,664 chars | OK | n/a |
| ~3,586 chars | OK | n/a |
| ~4,602 chars + tools | OK | Correct |

**Conclusion**: The system prompt limit bug does NOT reproduce on E4B with Ollama 0.20.5. This may be:
- Fixed in 0.20.5 (bug was reported against earlier versions)
- Specific to the 26B MoE variant only
- Dependent on specific prompt content/structure

**TODO**: Re-test on 26B MoE when set up on M5 Max.

## Thinking/Reasoning

Gemma 4 has built-in thinking support. The `reasoning` field in responses contains the model's chain-of-thought. This is separate from the `content` field.

- Thinking is enabled by default
- The `reasoning` field appears in both streaming and non-streaming responses
- In streaming mode, `reasoning` chunks arrive before `content` or `tool_calls`
- To disable thinking, you may need to configure the model (not yet tested)

## Context Window (num_ctx) — Critical

Ollama defaults to a **4,096 token context window** if `num_ctx` is not specified in the request. This is far too small for Tron — system prompt + tool definitions + conversation easily exceeds 10K tokens. When the context is exceeded, Ollama **silently truncates** the prompt, dropping tool definitions and earlier messages.

**Symptoms**:
- Model responds but doesn't use tools, or says "I don't have any tools"
- Model responds without thinking/reasoning (the `reasoning` field is absent from chunks)
- Model gives low-quality answers (most of the context was truncated)

**Critical discovery**: The `/v1/chat/completions` (OpenAI-compatible) endpoint **ignores** the `num_ctx` parameter entirely — whether at the top level or inside an `options` object. The only way to set `num_ctx` is via the **native `/api/chat`** endpoint's `options.num_ctx` field.

**Fix**: The Tron Ollama provider sends a lightweight warm-up request to `/api/chat` with `options.num_ctx` before the first streaming request. This forces Ollama to (re)load the model with the correct KV cache size. Subsequent requests via the OpenAI endpoint inherit this context size. For registered models, `num_ctx` is the model's context window capped at 32K. For unknown models, it defaults to 16K.

**Memory impact of num_ctx** (approximate, E4B with q8_0 KV cache):
| num_ctx | KV Cache Size | Total VRAM |
|---------|--------------|------------|
| 4,096 (default) | ~119 MB | ~9.7 GB |
| 16,384 | ~475 MB | ~10.1 GB |
| 32,768 | ~950 MB | ~10.6 GB |

On an M4 Pro 24GB, 32K context is comfortable. On M5 Max 36GB, even higher is fine.

## Latency Profile

With a typical Tron workload (system prompt + 8 tools + conversation):

| Phase | Duration | Description |
|-------|----------|-------------|
| Prompt evaluation | ~1.5s | Processing input tokens through all 42 layers |
| Model thinking | ~3-4s | Internal reasoning (the `reasoning` field) before producing output |
| Generation | ~1s | Producing the actual visible response tokens |
| **Total** | **~5-8s** | This is real model work, not a bug |

Short prompts without tools are much faster (~0.3s TTFT). The latency scales with input complexity.

## Known Limitations

1. **E4B is for validation only** — quality is limited for real agent work. Use 26B MoE for production.
2. **No auth required** — Ollama runs locally with no API keys needed.
3. **No streaming token usage** — Ollama doesn't report token counts in streaming mode. Cost is always $0 (local).
4. **Flash attention hang** — affects 31B Dense model on Apple Silicon with prompts >500 tokens. Does NOT affect E4B or 26B MoE.
5. **Memory pressure** — 26B MoE needs ~18GB+. On 24GB machines, this leaves limited headroom. Use 36GB+ for production.
6. **Ollama version sensitivity** — tool calling was broken in v0.20.0, fixed in v0.20.3. Always use latest.
7. **Model reload on context size change** — if `num_ctx` changes between requests, Ollama reloads the model (~3-5s). The Tron provider uses a consistent value per model to avoid this.
8. **`/v1/chat/completions` ignores `num_ctx`** — the OpenAI-compatible endpoint does not support context window configuration. Must use native `/api/chat` with `options.num_ctx` to set it. The Tron provider handles this automatically via a warm-up request.

## Hardware Recommendations

| Machine | Recommended Model | Notes |
|---------|------------------|-------|
| M4 Pro 24GB | gemma4:e4b | Validation/light use only. 26B MoE is tight. |
| M5 Max 36GB | gemma4:26b | Production. Comfortable headroom for 26B MoE + KV cache. |

## Service Management

```bash
brew services start ollama   # Start (auto-restarts on login)
brew services stop ollama    # Stop
brew services restart ollama # Restart
ollama list                  # List downloaded models
ollama rm <model>            # Remove a model
ollama show <model>          # Show model details
```

## Next Steps

- [ ] Pull and validate 26B MoE on M5 Max
- [ ] iOS Settings UI for Ollama provider
- [ ] Test thinking block display in iOS UI

# Capability Search Embedding Asset

This directory is the repo-owned, first-party embedding asset bundle used by
`domains::capability::embeddings`.

- Source: `Qdrant/all-MiniLM-L6-v2-onnx`
- Source revision: `5f1b8cd78bc4fb444dd171e59b18f3a3af89a079`
- License: Apache-2.0, included in `LICENSE-APACHE-2.0.txt`
- Runtime behavior: embedded into the Rust agent binary with `include_bytes!`
- Network behavior: no runtime model download

Required files:

| File | SHA-256 |
|------|---------|
| `model.onnx` | `bbd7b466f6d58e646fdc2bd5fd67b2f5e93c0b687011bd4548c420f7bd46f0c5` |
| `tokenizer.json` | `da0e79933b9ed51798a3ae27893d3c5fa4a201126cef75586296df9b4d2c62a0` |
| `config.json` | `1b4d8e2a3988377ed8b519a31d8d31025a25f1c5f8606998e8014111438efcd7` |
| `special_tokens_map.json` | `5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a` |
| `tokenizer_config.json` | `bd2e06a5b20fd1b13ca988bedc8763d332d242381b4fbc98f8fead4524158f79` |

`vocab.txt` and `README.md` are retained for provenance and inspection, but
the fastembed user-defined runtime consumes the files listed above.

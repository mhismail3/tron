---
paths:
  - "**/providers/**"
  - "**/*provider*"
  - "**/token-normalizer*"
---

# LLM Providers

Anthropic, OpenAI, and Google provider implementations with unified interface.

## Provider Structure

| Provider | File | Models |
|----------|------|--------|
| Anthropic | `anthropic.ts` | Claude 3.5/4 variants |
| OpenAI | `openai.ts` | GPT-4o, o1, o3 |
| Google | `google.ts` | Gemini 2.x |

## Key Exports (from `factory.ts`)

- `createProvider(config)` - Factory for provider instances
- `detectProviderFromModel(model)` - Infer provider from model ID
- `getModelCapabilities(model)` - Get model features (vision, etc.)

## Token Normalization

Providers report tokens differently. `token-normalizer.ts` unifies:
- `inputTokens` / `outputTokens` - Base usage
- `cacheReadTokens` / `cacheWriteTokens` - Prompt caching
- Handles Anthropic's cache_creation_input_tokens vs OpenAI's cached_tokens

## Adding a New Provider

1. Create `<provider>.ts` implementing Provider interface
2. Add model IDs to `models.ts`
3. Register in `factory.ts` createProvider switch
4. Add normalization in `token-normalizer.ts`
5. Test streaming and tool use

## Rules

- All providers must handle streaming with AbortSignal
- Token normalization is required for cost calculation
- Model detection is case-sensitive on prefixes

---

## Update Triggers

Update this rule when:
- Adding new provider implementations
- Changing token normalization logic
- Adding model capabilities

Verification:
```bash
grep -l "Provider" packages/agent/src/providers/factory.ts
grep -l "normalizeTokenUsage" packages/agent/src/providers/token-normalizer.ts
```

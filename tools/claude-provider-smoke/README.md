# Claude provider smoke (`scripts/tron provider-smoke`)

Tron serves Claude subscriptions (Pro, Max, Ultra) through Pi's built-in `anthropic` provider
and the OAuth login Pi keeps in `auth.json`. No provider package or fork is involved. This
tool is the gate for every Pi release that changes that path
([Pi SDK maintenance](../../packages/gateway/docs/pi-sdk-maintenance.md#claude-subscriptions)).

```bash
scripts/tron provider-smoke                  # offline probe, then the Gateway wiring tests
scripts/tron provider-smoke --probe-only     # offline probe only
scripts/tron provider-smoke --live --agent-dir <dir>   # plus at most six short real requests
scripts/tron provider-smoke --require-fable-5-2
```

## Offline probe

The probe reads the Gateway's pinned `pi-ai` through its export map. It reports:

- **The Claude Code version Pi claims.** It is read from the `user-agent` of one OAuth-shaped
  request sent to a local stub.
- **Whether `claude-fable-5-2` is in the built-in catalog.** Anthropic refuses Fable 5.2 to
  subscription requests that claim Claude Code below 2.1.290
  (`claude_code_version_too_old`). Fable 5.2 is `servable`, `absent`, or
  `listed-but-refused`. `listed-but-refused` fails, because Pi would offer a model every
  request to it is refused.
- **Opus 5.5's thinking levels.** `xhigh` and `max` are required.

Tron never patches the Claude Code version or Pi's request shaping. A model Pi cannot serve
waits for a Pi release.

## Wiring tests

The default run also runs these tests through `scripts/tron test gateway`:

- `home-anthropic-oauth-wire.integration.test.ts`: the OAuth bearer, Claude Code identity and
  betas; Home's one-hour view mark through `before_provider_request`; the `Bash` ↔ `bash`
  tool round trip; Opus 5.5 `xhigh` and `max`; and the usage card claiming the same Claude
  Code version as Pi.
- `provider-usage.integration.test.ts`: the usage card's bearer comes from `auth.json`, and
  Pi refreshes the login once under its lock.

## Live run

Run `--live` only with the maintainer's approval. It costs subscription usage.

- **Credential.** It reads the current access token from `<agent-dir>/auth.json` (no default:
  the maintainer names Stable or Debug) and never writes it. It refuses a token that expires within 30
  minutes. Every request goes through a fetch that refuses the OAuth token endpoint, so the
  stored login is never refreshed or rotated.
- **Requests.** It reads `/api/oauth/usage` before and after, and sends:
  - a Haiku 5.5 tool call;
  - the same call again, which must read at least 90% of the prefix from the cache;
  - Opus 5.5 at `xhigh`;
  - Opus 5.5 at `max`;
  - Fable 5.2, when Pi lists it.
- **Pass.** Every reply must carry `anthropic-ratelimit-unified-status: allowed` (billed to the
  plan), and spend or extra usage must not move.

## Verify

`node --test tools/claude-provider-smoke/smoke.test.mjs` runs the offline probe against the
pinned Pi, including the `--require-fable-5-2` gate.

# Tron delegation runtime provenance

This directory is a Tron-owned fork of the published `pi-subagents` package,
version `0.59.0`, used as source material under its MIT license. The exact
source archive was obtained with `npm pack pi-subagents@0.59.0` before the
fork was edited.

- npm package: `pi-subagents@0.59.0`
- npm registry integrity: `sha512-EOzArN0fU3AUQT+bjtq/8DfW8nSySTV43Qw97QFyChYBFX+GfmO3b7CgtelUfBqfg4gYmcq50B4MguAExIYM1g==`
- source archive SHA-256: `6d70145c895ebdc74569770dc436504e92a09ff1930e554c2aec1c25c012c50a`
- upstream repository: https://github.com/nicobailon/pi-subagents
- license: `LICENSE` (MIT)

The fork changes the extension identity to Tron, removes the upstream
scheduler and its public schema/RPC/help surfaces, and adds deterministic Tron
child bootstrap. It remains separately compiled by
`src/delegation/pi-subagents/tsconfig.json`; it is not compiled as Gateway
internal source. The packaged agent, skill, prompt, and documentation assets
are copied by `build.mjs` into the matching release payload directory.

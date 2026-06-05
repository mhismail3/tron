# Tron Maintainer Worker Pack

Local Worker Pack for maintaining this repository from Tron. It demonstrates
repo health summaries, focused test summaries, and scorecard/evidence artifact
creation inside the local worker-led autonomous work loop.

Suggested worker setup:

- Scope: workspace.
- Model preset: Balanced.
- Worker role: Review.
- Generated Controls target: `package` for configuration, activation, source
  checks, conformance, and removal.

Required configuration fields are `enabled`, `repoPath`, `scorecardPath`, and
`evidencePath`. Use repository-relative paths for docs fields.

No remote package discovery, source-control publishing, production rollout, or
personal information is part of this example.

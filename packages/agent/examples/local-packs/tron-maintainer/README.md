# Tron Maintainer Pack

Local example pack for maintaining this repository from Tron. It demonstrates
repo health summaries, focused test summaries, and scorecard/evidence artifact
creation without push, merge, release, deploy, or remote package discovery.

Recommended setup:

- Scope: workspace.
- Model preset: Balanced.
- Subagent role: Review.
- Generated UI target: `package` for configuration, activation, source checks,
  conformance, and removal.

Required configuration fields are `enabled`, `repoPath`, `scorecardPath`, and
`evidencePath`. Use repository-relative paths for docs fields.

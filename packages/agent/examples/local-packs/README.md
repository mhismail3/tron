# Local Worker Pack Examples

These Worker Packs are product examples for local-only Tron work loops. They are
templates, not a remote catalog. A registration flow materializes `worker.py`
and `../pack_runtime.py` as `materialized_file` resources, fills the resource
refs into `manifest.template.json`, computes `packageDigest`, and calls
`module::register_package`.

The three examples cover local worker-led autonomous work:

- `tron-maintainer`: Tron Maintainer Worker Pack for repo health, focused test
  summary, and scorecard/evidence helpers.
- `everyday-organizer`: Everyday Organizer Worker Pack for local digests,
  organizer artifacts, and local notification records.
- `creative-knowledge`: Creative Knowledge Worker Pack for prompt and notes
  transformation with Generated Controls oriented output.

All examples are local-process Worker Packs. No remote package discovery,
remote marketplaces, artifact publishing, production rollout, or personal
information is part of these examples.

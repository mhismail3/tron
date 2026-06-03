# Local Example Packs

These packs are product examples for local-only Tron package workflows. They are
templates, not a remote catalog. A registration flow materializes `worker.py`
and `../pack_runtime.py` as `materialized_file` resources, fills the resource
refs into `manifest.template.json`, computes `packageDigest`, and calls
`module::register_package`.

The three examples cover the product lanes required by TPROD-J:

- `tron-maintainer`: repo health, test summary, and scorecard/evidence helpers.
- `everyday-organizer`: local digest, organizer artifact, and local notification
  delivery.
- `creative-knowledge`: prompt and notes transformation with reusable generated
  UI-oriented output.

All examples are local-process packs. They do not implement remote package discovery,
call remote marketplaces, publish artifacts, or contain personal information.

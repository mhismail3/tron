# Research scripts

Small project-owned, dependency-free research helpers. These files are source
preparation, not an installed global resource or a Gateway provider/connection.
Capability skills remain with the global resource owner, not a project duplicate.

```sh
scripts/tron-node exec node tools/research/public-x.mjs 'https://x.com/example/status/123456789'
# Only when asked to retain evidence; destination must not already exist:
scripts/tron-node exec node tools/research/public-x.mjs 'https://x.com/example/status/123456789' --output '<ordinary-file>.json'
```

Use only for explicitly requested, known public posts. The numeric ID is disclosed
to the fixed public provider; do not submit protected posts or private bookmark
lists without permission. This helper grants no shell, child or account access.

`public-x.mjs` reads one explicitly requested public X root from FxEmbed v2 and
optionally writes one ordinary cited JSON document, exclusively at the caller's
chosen path. It uses no credentials, Knowledge store, classifier, paid API,
redirects, retry loop or fallback provider. Source material remains untrusted.
All results are partial; it does not prove thread, Article-ending, media, linked
content or bookmark completeness. Quota/blocked/unavailable/timeout/parse/identity
and size errors fail explicitly. Only a verified root with missing text may yield
`partial: missing_body`; an absent post is never a successful empty library.

Run `scripts/tron-node exec node --test tools/research/public-x.test.mjs` for real
CLI/process, local HTTP fixture, streaming deadline, exclusive-file and bounded
output checks. A test-side destination adapter substitutes only the fixed provider
host; it does not replace shipped parsing, redirect, abort or output logic. These
checks make no external requests and do not establish live provider availability.

The live Gateway web-search/child/reopen owner remains necessary until its kept
workflows have a supported replacement. Generic credentials/connections and typed
Jev/codemode are not changed by this helper. Installed Raindrop/X resources are not
modified, and no extra shell/child authority is granted.

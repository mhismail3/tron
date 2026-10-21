# Scoped learned profile

Knowledge notes remain the sole authority for rule text, identity, revisions and
confirmation. A profile **file** is a labelled partition of those notes, not a
second editable text store: `home-profile`, one `kind-*`, and one `home-file-*`
label. The file label encodes `core`, `home` or `scopes/<lowercase-slug>`.

## Selection and bounds

- `core` loads on every Home activation and every delegated brief.
- `home` loads on every Home activation, never automatically into workers.
- `scopes/<name>` holds contextual facts, not binding rules. Home always sees a
  one-line index; `profile read {file}` reads a file on demand.
- `delegate {scopes: [name]}` adds exactly those files to core. Missing/unknown
  names keep core and return a diagnostic to Home and in the worker brief.
- The Gateway writes `## Preferences applied` and applied note IDs itself. Home
  must not manually copy all profile text into `intent`.
- Precedence is scope > home > core; confirmed beats inferred. No rule is silently
  deduplicated. Home compares proposed natural-language rules and supplies known
  contradictions in `contradicts`; the Gateway refuses a flagged save. Explicit
  supersession is the reviewed replacement path, not semantic string guessing.
- Each file caps active rendered rule lines at 4,096 UTF-8 bytes, including IDs,
  kind/status labels and newlines. There are at most 16 active scopes. `learn`,
  `refine`, `supersede`, `confirm` and migration validate projected size before
  writing; the refusal names the file, projected bytes and cap.
- Accepted/imported rules are not truncated on load, even when over cap. The
  diagnostic appears in instructions and the `session.diagnostic` event stream
  (`home-profile-load`). A missing/corrupt Knowledge record is isolated; healthy
  records continue loading. An unavailable Knowledge namespace is reported as
  unavailable, never as an empty profile.

Every item exposes its full note ID, file, one-line text, kind, inferred/confirmed
state, short rationale (Knowledge provenance reason) and last-confirmed date
(`null` when never confirmed). Confirmation labels retain the date across later
inferred refinements. Retirement/supersession status is still derived by the
existing Knowledge/Changes owners.

The core budget is larger than a tiny instruction header so full binding text and
stable IDs fit without rewriting or dropping existing rules. Home-only operations
belong in home; product architecture belongs in the owning repository's rules;
model queue choices belong in Settings, not interpreted prose.

## One-time organization and undo

`home.profileChange` or `profile migrate` takes `assignments`, exactly one
`{id, expectedRevision, file}` for every current profile note, including inactive
notes. Home uses the maintainer-approved mapping; there is no content heuristic,
hardcoded personal-note ID table, startup mutation or hidden model call.

1. Check the complete assignment set, revision fences, file names, binding-rule
   placement and caps.
2. Knowledge durably writes `state/knowledge/profile-backup-<command-hash>.json`
   with the original notes and complete committed revision references.
3. One Knowledge catalog transaction advances all changed heads, changing only
   file labels. IDs, text, kind, confirmation, retirement, provenance, relations,
   timestamps and earlier immutable revisions remain intact. A failure leaves
   every previous head authoritative.
4. The settings change path records the group in Changes; undo restores the old
   labels/content through the existing revision fences. Undo does not delete
   history. Repeating an identical organization makes no writes; later moves use
   `refine {file}`, not another migration.

Unlabelled persisted notes remain applied as legacy core until explicit
organization or undo restoration. This is the real persisted consumer, not a
second profile format or a silent empty fallback. Every read resolves current
Knowledge heads; edits apply next Home activation and next delegation with no
Gateway restart. In-flight activations keep their frozen instructions.

## Validation

`src/sessions/home-profile.integration.test.ts` uses real Registry/Gateway/Pi
sessions and a faux provider for scoped selection, binding-rule load, save caps,
record corruption isolation, migration/history/undo and next-turn/brief reload.
Its regenerable artifact is `test-results/home-profile/report.json`.

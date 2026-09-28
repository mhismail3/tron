# Knowledge dashboard presentation

The dashboard has one top-level segmented row: **Chronicle** and **Library**.
Chronicle's observations, coverage attention list, and bounded coverage stats are
opened from its logo menu. Library chooses **Sources** or **Syntheses** and source
visibility (saved, pending, or archived) from its filter sheet; those choices are
mutually exclusive and never mutate canonical admission.

## Knowledge Sources presentation

The Sources library is a user-facing reading surface, not a storage inspector.
Rows are one fixed compact height: a title of at most two lines and one
domain/type line in the standard settings-row subtext size, beside a bounded
square preview centered on that text block. The preview is the Gateway-captured
safe JPEG, PNG, or WebP page preview or X Article cover image; sources without
one use a deterministic domain/title fallback. Summaries, intake assessments,
and routine capture/admission state are not shown in rows.

The **Entry Detail** sheet leads with one header container: preview and title,
with a right-aligned pill naming the original link's domain. The pill opens the
page in the in-app browser (`TronSafariView`, the same full-bleed
`SFSafariViewController` sheet public webpage displays use). The original link
is the source of truth. The Gateway keeps the captured bytes and readable
extraction as a backup and as model input, but the sheet does not expose them as
reading surfaces: a raw HTML object is not readable, and page extraction
includes site chrome. Everything else is inline in the same sheet, with no
secondary details sheet: the **Summary** group (a generated summary with its
grounded tags, or a **Generate AI summary** button row), a **Details** table in
the standard metadata-table layout (type, publication/save/capture dates,
capture state, origin, media type, revision), saved notes, related entries that
open at their current revision, links declared in the entry (in-app browser),
and capture coverage when the capture is incomplete.
For redirected connector captures, the original-link pill uses the requested URL
recorded for that exact saved-item identity in origin provenance; the resolved
page URI remains capture metadata. Unrelated referral origins are never used as
the original link, and the same HTTP(S)-only URL safety policy still applies.
The Raindrop `created` timestamp is the originating save time, not a publication
date. Historical Raindrop records with the old misfiled `created` timestamp are
not mislabeled as publication dates; absent origin-save dates stay absent and
Tron capture time is labeled separately.

Opening a source never invokes model generation. **Generate AI summary** is an
explicit per-source action using the configured Knowledge model and saved readable
text only; it never fetches linked pages or implies complete thread/discussion
coverage. The bounded result is persisted separately from the Jev intake assessment,
with its source revision, evidence digest, generation time, and full/sampled coverage.
A stale summary is withheld when its title/text evidence changes, and the button becomes **Regenerate AI summary**. Summaries and
grounded semantic/keyword tags are generated together and are interpretation, not
replacements for immutable captured evidence. Partial or bounded excerpts are
labeled sampled; linked pages are never inferred as covered.
Assessment usage prices are fractional cents (`Double`), matching the Gateway's
numeric contract; token counts remain integers. The native RPC regression decodes
a full source page containing both a preview and sub-cent assessment usage.
New assessments carry an `evidenceDigest` of Gateway `JSON.stringify({title, text})`.
iOS reproduces those UTF-8 bytes without Foundation's default slash escaping.
A mismatch with the current title/text withholds the obsolete summary; metadata
and admission changes alone do not invalidate it. Older unbound assessments remain
stored summaries, not a certification of current evidence. The Gateway and native
regressions share a URL, quote, newline, and Unicode digest vector.

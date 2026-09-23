# Knowledge dashboard presentation

The dashboard has one top-level segmented row: **Chronicle** and **Library**.
Chronicle's observations, coverage attention list, and bounded coverage stats are
opened from its logo menu. Library chooses **Sources** or **Syntheses** and source
visibility (saved, pending, or archived) from its filter sheet; those choices are
mutually exclusive and never mutate canonical admission.

## Knowledge Sources presentation

The Sources library is a user-facing reading surface, not a storage inspector.
Rows show a title, optional generated content summary, domain/type, and a bounded
square preview when the Gateway captured a safe JPEG, PNG, or WebP page-preview
or X Article cover image. Intake assessments are not presented as content summaries.
Sources without a preview use a deterministic domain/title fallback.
Routine capture and admission state is intentionally hidden from rows; actionable
limitations appear in **More source details**.

Source details lead with an explicit content summary (when generated), original
link, and source publication/save dates when the source system provides them.
For redirected connector captures, **Open original** uses the requested URL
recorded for that exact saved-item identity in origin provenance; the resolved
page URI remains capture metadata. Unrelated referral origins are never used as
the original link, and the same HTTP(S)-only URL safety policy still applies.
The Raindrop `created` timestamp is the originating save time, not a publication
date. Historical Raindrop records with the old misfiled `created` timestamp are
not mislabeled as publication dates; absent origin-save dates stay absent and
Tron capture time is labeled separately.
Additional tags, metadata, nested links, references, and capture details live in
a separate **More source details** sheet. Saved text stays a progressive disclosure.
Raw objects and provider representations remain in technical details.
The saved-text reader uses the extracted text, including sources without a raw
object, and provides Previous/Next pages of at most 12,000 characters. Raw-file
inspection is separate and bounded; it does not replace the readable source.
Full stored summaries are available in detail; row line limits keep the list compact.

An absent content summary is shown honestly as **No content summary yet**.
Opening a source never invokes model generation. **Generate AI summary** is an
explicit per-source action using the configured Knowledge model and saved readable
text only; it never fetches linked pages or implies complete thread/discussion
coverage. The bounded result is persisted separately from the Jev intake assessment,
with its source revision, evidence digest, generation time, and full/sampled coverage.
A stale summary is withheld when its title/text evidence changes. Summaries and
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

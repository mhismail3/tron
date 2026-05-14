---
name: "Publish Website"
description: "Write, update, and publish blog posts and portfolio entries to the user's personal website"
version: "2.0.0"
tags: [writing, publishing, website]
---

Write, update, and publish blog posts and portfolio project entries to the user's personal website. The site is a React SPA deployed via GitHub Pages.

## Required config

This skill needs three values to know where your site lives:

| Field | Meaning | Example |
|---|---|---|
| `domain` | Public URL of your site | `example.com` |
| `local_repo` | Local clone path | `~/Workspace/my-website` |
| `github_handle` | GitHub user/org that owns the repo | `your-username` |

These live in `~/.tron/memory/rules/publish-website.md` (auto-listed in your memory footer). Workflow:

1. Read `~/.tron/memory/rules/publish-website.md`.
2. If the file doesn't exist or lacks any of the fields above, ask the user and save them. Write the file with YAML frontmatter:
   ```yaml
   ---
   description: Publish-website config (domain, repo, GitHub handle)
   ---
   domain: example.com
   local_repo: ~/Workspace/my-website
   github_handle: your-username
   ```
3. Use the values throughout the workflow. NEVER hardcode them into scripts or other skills — always read from `rules/publish-website.md`.

If the site's GitHub repo URL differs from `github.com/<github_handle>/<basename(local_repo)>`, add a `github_repo_url:` field.

## Workflow

### Creating new content

1. **Understand the request** — Determine content type (blog long, blog mini, portfolio), topic, any references or links the user wants included.
2. **Voice calibration** — Read 2-3 existing posts from the repo before drafting. This is mandatory. Pick posts topically close to the new content. Use `filesystem::read_file` on files in `<local_repo>/public/posts/` or `<local_repo>/public/projects/`.
3. **Draft the content** — Write the full post following the style guide and templates below. Match the voice from the posts you just read.
4. **Review gate** — Present the complete draft to the user. Iterate until they approve. Never commit or push without explicit approval.
5. **Create the file** — Write to the correct path using the file naming conventions below. If the post references images, note which images are needed.
6. **Commit and push** — From `<local_repo>`, run `git add`, `git commit`, `git push origin main`.
7. **Open the URL** — Use the `OpenURL` tool to open the published page:
   - Blog: `https://<domain>/posts/YYYY-MM-DD-slug`
   - Portfolio: `https://<domain>/portfolio/slug`

### Updating existing content

1. **Find the post** — Locate the file to update. List posts with `filesystem::find` on `public/posts/*/post.md` or `public/projects/*/project.md`, or search by keyword with `filesystem::search_text`. Read the full file with `filesystem::read_file`.
2. **Understand the changes** — Clarify what the user wants changed: new sections, rewording, updated frontmatter (tags, date, status), added/removed content, factual corrections, etc.
3. **Voice calibration** — If the edit involves writing new prose (not just fixing a typo or updating a tag), read 1-2 nearby posts to recalibrate voice. Skip this for mechanical edits.
4. **Draft the changes** — Show the user what will change. For small edits, present a before/after of the affected section. For large rewrites, present the full updated post.
5. **Review gate** — Get explicit approval before writing. Same rule as new content: never commit without approval.
6. **Apply the edit** — Use `filesystem::edit_file` for targeted changes, `filesystem::write_file` for full rewrites. Do not change the file path or folder name (the slug is part of the URL — renaming breaks links).
7. **Commit and push** — From `<local_repo>`, run `git add`, `git commit`, `git push origin main`.
8. **Open the URL** — Same as new content.

## Blog post reference

### Long posts

Frontmatter template:

```yaml
---
title: "Post title here"
date: "YYYY-MM-DDTHH:MM:SS-08:00"
tags:
  - tag1
  - tag2
enableTableOfContents: true  # optional, for posts with multiple sections
---
```

Structure:
- Opening hook — 1-2 paragraphs that establish the context or tell a quick story. Get the reader oriented fast.
- `---` horizontal rule separator after the hook
- Body with `##` and `###` headings in sentence case. Short paragraphs (2-4 sentences).
- Closing — usually a link to the GitHub repo and/or a forward-looking sentence. Keep it brief.

Typical length: 1500-3500 words.

### Mini posts

Frontmatter template:

```yaml
---
date: "YYYY-MM-DDTHH:MM:SS-08:00"
type: mini
tags:
  - tag1
---
```

Mini posts have no title. They're for quick thoughts, quotes, reactions to news, or brief announcements. 50-200 words. Use these for:
- Quotes (use `>` blockquote with attribution)
- Quick reactions to AI news or product launches
- Small website feature announcements
- Brief commentary that doesn't warrant a full post

## Portfolio project reference

Frontmatter template:

```yaml
---
title: Project Name
slug: project-slug
date: YYYY-MM-DD
summary: One or two sentences describing the project and its key technical aspects.
github: https://github.com/<github_handle>/repo-name
live: https://live-url.com  # optional
tags:
  - TypeScript
  - React
  - Other Tech
status: "🔄 Active"
cover: cover.png
excludeCoverFromCarousel: false  # optional, default false
gallery:
  - gallery-1.png
  - gallery-2.png
---
```

Status options: `"🔄 Active"`, `"🚀 Shipped"`, `"📥 Shelved"`, `"🗄️ Archived"`

Body structure: Use `##` headings to break the project into sections. Explain the interesting technical decisions and architecture. Link back to related blog posts where applicable.

**Important**: Portfolio tags use Title Case (`TypeScript`, `SwiftUI`, `AI Agents`), while blog tags use lowercase (`ai`, `typescript`, `automation`).

## Writing style guide

### Tone

- First-person, conversational. Write like you're telling a friend what you built.
- Reflective and honest — acknowledge limitations, mention things that didn't work, share what you learned.
- Enthusiastic without being performative. It's fine to say something is cool, but don't oversell it.
- Personal opinions stated directly. "I think X" not "one might argue X."

### Structure

- Hook-first opening. Start with the interesting thing, not background context.
- `---` horizontal rule after the opening hook (long posts only).
- Headings in sentence case: "What gets installed" not "What Gets Installed."
- Short paragraphs. 2-4 sentences max. Let the content breathe.
- End with a GitHub link or brief forward-looking note, not a grand conclusion.

### Formatting

- **Bold** for key terms on first use.
- `inline code` for technical terms, commands, file names, config values.
- Code blocks with language tags (```bash, ```yaml, ```markdown, etc.).
- Footnotes via `^[text]` for asides, citations, and tangential thoughts.
- Em dashes — used sparingly for interjections, not as a substitute for commas.
- Straight quotes only. No curly/smart quotes.
- All dates in Pacific timezone (`-08:00`).
- Images referenced as `![alt text](filename.png)` with the image in the same folder.

### Anti-slop list

Never use these words or patterns:

- "delve", "tapestry", "landscape", "paradigm", "synergy", "leverage" (as verb), "utilize", "facilitate", "robust" (when describing anything other than literal robustness), "streamline", "harness" (as verb meaning "use"), "empower", "elevate", "curate", "craft" (as verb for writing), "embark", "journey" (metaphorical), "realm", "beacon", "cornerstone", "game-changer" (except in direct quotes), "deep dive" (as noun)
- No rule-of-three constructions ("X, Y, and Z" used rhetorically where each item restates the same idea)
- No "In conclusion" or "In summary" closings
- No promotional language ("you'll love", "incredibly powerful", "must-have")
- No emojis in prose (emojis are fine in frontmatter status fields only)
- No Title Case headings — use sentence case
- No rhetorical questions as transitions ("But what about X?", "So how does this work?")
- No "Let's" constructions ("Let's take a look", "Let's dive in")
- No "without further ado"

### Voice calibration

Before drafting new content, read 2-3 existing posts from the user's repo to match their voice. The style guide above describes conventions, but voice calibration matters most — the posts you read are ground truth.

## Existing tag registry

Tag registries (lowercase for blog, Title Case for portfolio) live in the user's repo, built up over time. List existing tags before drafting new content:

```bash
# Blog
ls <local_repo>/public/posts/*/post.md | xargs grep -h '^- ' | sort -u

# Portfolio
ls <local_repo>/public/projects/*/project.md | xargs grep -h '^  - ' | sort -u
```

Reuse existing tags before inventing new ones. If a genuinely new topic comes up, add a new tag in the matching case convention.

## File naming conventions

**Blog posts**: `public/posts/YYYY-MM-DD-slug-in-lowercase/post.md`
- Slug derived from the title, all lowercase, hyphens for spaces
- Example: `public/posts/2026-02-28-my-new-post-about-something/post.md`

**Portfolio projects**: `public/projects/slug/project.md`
- Slug must match the frontmatter `slug` field exactly
- Example: `public/projects/my-project/project.md`

**Images**: Place in the same folder as the markdown file, reference as `![alt](filename.png)`.

## Pre-publish checklist

1. YAML frontmatter is valid (no trailing spaces, proper quoting)
2. Date uses correct format — ISO 8601 with `-08:00` for blog, `YYYY-MM-DD` for portfolio
3. Blog tags are lowercase, portfolio tags are Title Case
4. Mini posts have `type: mini` and no `title` field
5. Long posts have the `---` separator after the opening hook
6. All referenced images exist in the same folder
7. No words from the anti-slop list appear in the draft
8. Headings use sentence case, not Title Case
9. File path matches the naming convention exactly
10. The draft has been explicitly approved by the user before committing

## Gotchas

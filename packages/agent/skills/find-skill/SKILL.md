---
name: "Find Skill"
description: "Search online skill repositories, evaluate candidates, and install the best match to ~/.tron/skills/"
version: "1.0.0"
tags: [skills, discovery, install, package-manager]
deniedTools: [SpawnSubagent]
---

# Find Skill — Skill Discovery & Installation

Search online skill repositories for a skill matching the user's need, evaluate candidates for quality and safety, and install the best match into `~/.tron/skills/`.

## Prerequisites

`npx skills` is the primary CLI. It's auto-downloaded by npx on first use — no global install needed.

Verify availability:
```bash
npx skills --version
```

If `npx` is unavailable (shouldn't happen with Node installed), fall back to manual git clone (see Phase 6).

## Phase 1: Parse the Request

Extract the core need from the user's query. If vague, ask a clarifying question before searching.

Good: "find a skill for creating unit tests" -> search terms: `unit test`, `testing`, `test generation`
Vague: "find me something useful" -> ask: "What kind of task do you want a skill for?"

Generate 2-3 search term variations from the request.

## Phase 2: Search

Run these searches in parallel:

### 2a. CLI index search
```bash
npx skills find "<primary-query>"
```

### 2b. Browse the skills.sh registry
WebFetch `https://skills.sh` and search for the query. This is the primary public skills directory (built by Vercel) with ranked listings and install counts.

### 2c. Web search
Use WebSearch with queries like:
- `"SKILL.md" <query> site:github.com`
- `claude code skill <query>`
- `agent skill <query> site:skills.sh`

### 2d. Curated repositories
Check known trusted sources when relevant:
- `anthropics/skills` — official Anthropic skills collection (50+ skills)
- `vercel-labs/agent-skills` — Vercel curated collection (react best practices, web design, deploy)

Use WebFetch on their GitHub repos to browse available skills and match against the query.

### When to use `npx openskills` instead

`openskills` is a separate CLI (`npx openskills`) for cross-agent skill management. Use it if:
- `npx skills find` returns no results
- The user specifically asks for openskills
- You need to search private or self-hosted skill registries

Key differences from `npx skills`:
- Install command: `npx openskills install <source> --global -y` (not `add`)
- No `-a` agent flag — installs to `~/.claude/skills/` by default with `--global`
- Has `npx openskills read <name>` to preview skill content

## Phase 3: Evaluate Candidates

Score each candidate on these criteria:

| Criterion | Weight | What to check |
|-----------|--------|---------------|
| Trust | High | Known org? Stars? Active maintenance? |
| Relevance | High | Does it actually solve the user's need? |
| SKILL.md quality | Medium | Well-structured? Clear instructions? Reasonable tool usage? |
| Recency | Medium | Last commit/update date |
| Security posture | Critical | See red flags below |

### Security Red Flags — Hard Reject

Reject any skill that:
- Fetches and executes remote scripts (`curl | sh`, `wget | bash`, etc.)
- Requests credentials, tokens, or API keys beyond what the task requires
- Contains obfuscated or encoded content (base64 blobs, hex-encoded strings)
- Uses unrestricted Bash without clear justification
- Writes outside its working directory without explanation
- Has no SKILL.md or an empty/placeholder one

## Phase 4: Present Options

Use AskUserQuestion to present a ranked shortlist (2-4 candidates).

For each candidate, show:
- Name and source (repo URL)
- What it does (1 sentence)
- Trust signal (stars, org, maintenance status)
- Any concerns

Always include a "None of these" option. If the user picks none, offer to refine the search or try different terms.

## Phase 5: Install

After the user picks a candidate, follow these steps exactly:

### Step 1: Download via CLI

The source can be an `owner/repo` GitHub reference, a full GitHub URL, or a registry skill name:

```bash
# From a GitHub repo (most common)
npx skills add owner/repo -g -a claude-code -y

# Specific skill from a multi-skill repo
npx skills add owner/repo -s skill-name -g -a claude-code -y

# From a GitHub URL
npx skills add https://github.com/owner/repo -g -a claude-code -y
```

Flags: `-g` installs globally to `~/.claude/skills/`, `-a claude-code` targets Claude Code agent format, `-s` selects a specific skill from a multi-skill repo, `-y` skips confirmation prompts.

### Step 2: Locate and read the downloaded SKILL.md

```bash
ls ~/.claude/skills/
```

Find the newly downloaded skill directory and use the Read tool to inspect its SKILL.md content. **This is the security gate.** Review:
- What tools does it request?
- Does it write files outside expected directories?
- Does it run any suspicious Bash commands?
- Is the content coherent and well-structured?

If anything looks suspicious, **stop and warn the user** with specifics about what's concerning. Do not proceed unless the user explicitly confirms.

### Step 3: Copy to `~/.tron/skills/`

```bash
cp -r ~/.claude/skills/<skill-name> ~/.tron/skills/<skill-name>
```

### Step 4: Patch frontmatter if needed

Read the copied SKILL.md. If it's missing required frontmatter fields, add them:

Required fields:
- `name` — derive from directory name if missing
- `description` — derive from first paragraph if missing

Use the Edit tool to add missing frontmatter. Don't overwrite existing fields.

### Step 5: Verify installation

```bash
ls -la ~/.tron/skills/<skill-name>/SKILL.md
```

Read the final file back and confirm it's valid.

## Phase 6: Fallback — Manual Install

When CLI tools don't have the skill (niche repos, specific GitHub URLs):

```bash
# Clone just the skill directory
git clone --depth 1 --filter=blob:none --sparse <repo-url> /tmp/skill-install
cd /tmp/skill-install && git sparse-checkout set <path-to-skill>
```

Then follow Steps 2-5 from Phase 5 (read, review, copy, patch, verify).

Clean up:
```bash
rm -rf /tmp/skill-install
```

## Post-Install

Tell the user:
1. **How to invoke**: `@<skill-name>` in the chat
2. **What it does**: one-sentence summary from the SKILL.md description
3. **What tools it uses**: list any notable tool access (Bash, web access, file writes, etc.)
4. **Subagent mode**: whether it runs inline or as a subagent

## Safety Rules

1. **Never install without user confirmation.** Always present candidates and let the user choose.
2. **Always read SKILL.md content before copying to `~/.tron/skills/`.** This is non-negotiable.
3. **Prefer trusted sources.** Official repos and well-starred projects over random forks.
4. **Warn on unrestricted Bash.** If a skill doesn't deny Bash and its instructions involve shell commands, note this to the user.
5. **Don't overwrite existing skills.** If `~/.tron/skills/<name>/` already exists, tell the user and ask whether to replace, rename, or skip.
6. **Clean up temp files.** Remove any `/tmp/skill-install` directories after use.
7. **One skill per invocation.** Search for and install one skill at a time. If the user wants multiple, handle them sequentially.

## Gotchas

# System Prompt Customization

Tron's system prompt defines the agent's identity, available tools, and behavioral guidelines. By default, Tron uses a built-in prompt, but you can customize it using `SYSTEM.md` files.

## Table of Contents

- [Overview](#overview)
- [File Locations](#file-locations)
- [Priority Order](#priority-order)
- [Getting Started](#getting-started)
- [Best Practices](#best-practices)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Technical Details](#technical-details)

## Overview

The system prompt is the foundational instruction that shapes how Tron behaves. It:

- Defines Tron's identity and purpose
- Lists available tools and their usage
- Sets behavioral guidelines and constraints
- Establishes response style and patterns

Custom system prompts let you:
- Tailor Tron to specific project needs
- Enforce project-specific coding standards
- Define domain-specific behaviors
- Create specialized agents for different workflows

## File Locations

System prompts follow a hierarchical pattern similar to `AGENTS.md` and `CLAUDE.md`:

### Global Prompt
**Location:** `~/.tron/SYSTEM.md`

- Applies to all projects by default
- Useful for personal preferences and general patterns
- Good for tool usage patterns you prefer across projects

### Project Prompt
**Location:** `.tron/SYSTEM.md` (in project root)

- Overrides global prompt completely (no merging)
- Project-specific behavior and constraints
- Shared with team via version control
- Ideal for enforcing project conventions

## Priority Order

When Tron initializes, it loads the system prompt following this priority:

1. **Programmatic override** (highest) - Via `systemPrompt` parameter in code
2. **Project prompt** - `.tron/SYSTEM.md` in project
3. **Global prompt** - `~/.tron/SYSTEM.md` in home directory
4. **Built-in default** (fallback) - Hardcoded `TRON_CORE_PROMPT`

**Important:** Project prompts completely replace global prompts (no merging). Choose one location for your customization.

## Getting Started

### 1. View the Default Prompt

The default prompt is located in the source code at:
```
packages/core/src/context/system-prompts.ts
```

Current default (simplified):
```markdown
You are Tron, an AI coding assistant with full access to the user's file system.

You have access to the following tools:
- read: Read files from the file system
- write: Write content to files
- edit: Make targeted edits to existing files
- bash: Execute shell commands
- grep: Search for patterns in files
- find: Find files by name or pattern
- ls: List directory contents

When working with code:
1. Read existing files to understand context before making changes
2. Make targeted, minimal edits rather than rewriting entire files
3. Test changes by running appropriate commands when asked
4. Explain what you're doing and why
```

### 2. Create Your First Custom Prompt

**For global customization:**
```bash
mkdir -p ~/.tron
cat > ~/.tron/SYSTEM.md << 'EOF'
You are Tron, a specialized coding assistant focused on clean, maintainable code.

You have access to: read, write, edit, bash, grep, find, ls

Guidelines:
- Read files before modifying them
- Make minimal, targeted changes
- Explain your reasoning
- Follow DRY principles
EOF
```

**For project-specific customization:**
```bash
mkdir -p .tron
cat > .tron/SYSTEM.md << 'EOF'
You are Tron, a TypeScript expert for this React project.

Available tools: read, write, edit, bash, grep, find, ls

Project conventions:
- Use functional components with hooks
- Follow Airbnb style guide
- Write unit tests for all components
- Keep components under 200 lines
EOF
```

### 3. Verify It Works

The prompt loads automatically on session start. To verify:

1. Start a new Tron session
2. Check logs for "Loaded system prompt from: project" or "global"
3. Ask Tron to describe itself - it should reflect your customizations

## Best Practices

### Length and Tokens

- **Recommended:** 500-1000 tokens (~2-4KB of text)
- **Maximum:** 100KB (~25,000 tokens, enforced limit)
- **Tip:** Be concise - every token in the system prompt counts against context

### Content Guidelines

**Do include:**
- Core identity and purpose
- Critical project-specific constraints
- Key behavioral guidelines
- Tool usage patterns specific to your workflow

**Don't include:**
- Detailed tool descriptions (Tron already knows)
- Redundant information from Skills or Rules
- Examples and tutorials (use Skills instead)
- Frequently changing information

### Style

**Good:**
```markdown
You are Tron, a Python expert for data science projects.

Tools: read, write, edit, bash, grep, find, ls

Standards:
- Follow PEP 8
- Use type hints
- Write docstrings for all functions
- Prefer pandas over loops
```

**Verbose (avoid):**
```markdown
You are Tron, an extremely helpful and knowledgeable AI coding
assistant who specializes in Python programming, particularly
focused on data science and machine learning projects...

You have access to the following powerful tools:
- read: This amazing tool allows you to read files from the
  file system. You can use it to examine source code...
[continues for 500 more lines]
```

### Maintenance

- **Version control:** Commit `.tron/SYSTEM.md` to share with team
- **Regular updates:** Review and refine as project evolves
- **Team alignment:** Discuss changes with team before modifying shared prompts

## Examples

### Minimal TypeScript Project

```markdown
You are Tron, a TypeScript assistant for this project.

Tools: read, write, edit, bash, grep, find, ls

Rules:
- Use strict mode
- No `any` types
- Prefer `const` over `let`
- Write tests for new code
```

### Security-Focused

```markdown
You are Tron, a security-conscious assistant.

Tools: read, write, edit, bash, grep, find, ls

Security priorities:
- Never log sensitive data
- Validate all inputs
- Use parameterized queries
- Check OWASP Top 10 before suggesting code
- Warn about security implications
```

### Documentation-Heavy

```markdown
You are Tron, focused on maintainability and documentation.

Tools: read, write, edit, bash, grep, find, ls

Documentation standards:
- JSDoc for all public functions
- README for each major module
- Inline comments for complex logic
- Keep docs up-to-date with code changes
```

### Test-Driven Development

```markdown
You are Tron, a TDD practitioner for this project.

Tools: read, write, edit, bash, grep, find, ls

TDD workflow:
1. Write failing test first
2. Implement minimal code to pass
3. Refactor while keeping tests green
4. Never commit failing tests
```

## Troubleshooting

### Prompt Not Loading

**Check file location:**
```bash
# Global
ls -la ~/.tron/SYSTEM.md

# Project
ls -la .tron/SYSTEM.md
```

**Check file permissions:**
```bash
chmod 644 ~/.tron/SYSTEM.md
chmod 644 .tron/SYSTEM.md
```

**Enable debug logging:**
```bash
# Set log level to debug to see prompt loading messages
export TRON_LOG_LEVEL=debug
```

### File Too Large

If you see "SYSTEM.md exceeds size limit" in logs:

```bash
# Check file size
ls -lh .tron/SYSTEM.md

# File must be < 100KB
# If larger, simplify your prompt or move content to Skills
```

### Wrong Prompt Being Used

**Priority debugging:**
```bash
# Check which files exist
ls -la ~/.tron/SYSTEM.md        # Global
ls -la .tron/SYSTEM.md           # Project

# Remember: Project overrides global completely
# Delete project file to test global
rm .tron/SYSTEM.md
```

### Changes Not Reflected

System prompts are loaded once per session. To reload:
1. Exit current Tron session
2. Start new session
3. Changes will take effect

## Technical Details

### Implementation

- **Location:** `packages/core/src/context/system-prompts.ts`
- **Loading:** Synchronous file read on `ContextManager` construction
- **Caching:** Loaded once per session, cached in memory
- **Performance:** ~2-5ms overhead at session initialization

### API Usage

For programmatic customization:

```typescript
import { createContextManager } from '@tron/core';

const cm = createContextManager({
  model: 'claude-sonnet-4-20250514',
  workingDirectory: '/path/to/project',
  userHome: '/home/user',
  // Programmatic override (highest priority)
  systemPrompt: 'Custom prompt content',
});
```

### Provider Compatibility

System prompts work with all providers:

- **Anthropic:** Standard system prompt
- **OpenAI:** Standard system prompt
- **Google:** Mapped to `systemInstruction`
- **OpenAI Codex:** Injected via tool clarification message

### File Format

- **Format:** Plain text markdown
- **Encoding:** UTF-8
- **Size limit:** 100KB (enforced)
- **Empty files:** Valid (results in minimal prompting)

### Differences from Skills

| Feature | System Prompt | Skills |
|---------|--------------|---------|
| **Purpose** | Core identity | Reusable context |
| **When loaded** | Session start | On-demand or auto-inject |
| **Scope** | Global behavior | Specific capabilities |
| **File count** | One per location | Many files possible |
| **Override** | Complete replacement | Additive (merged) |
| **Best for** | Behavioral guidelines | Domain knowledge |

## Related Documentation

- [Skills System](./skills.md) - For reusable context packages
- [Rules System](./rules.md) - For project-specific conventions
- [Context Management](./context.md) - Understanding Tron's memory

## FAQ

**Q: Can I use both global and project prompts?**
A: No, project prompts completely replace global prompts. Choose one location.

**Q: Should I commit `.tron/SYSTEM.md` to version control?**
A: Yes, if you want to share the prompt with your team. Add it to git.

**Q: How is this different from AGENTS.md/CLAUDE.md?**
A: Those files define rules and context that merge hierarchically. SYSTEM.md defines Tron's core identity and completely overrides at each level.

**Q: Can I use variables or templating?**
A: No, prompts are static text. For dynamic content, use Skills or programmatic API.

**Q: What happens if the file is deleted mid-session?**
A: The cached prompt continues to be used. New sessions will fall back to the next priority level.

**Q: Can I disable the built-in default prompt?**
A: Create an empty `SYSTEM.md` file for minimal prompting, but this may reduce effectiveness.

---

**Last updated:** 2026-01-14
**Version:** 1.0.0

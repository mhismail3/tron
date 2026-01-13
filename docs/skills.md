# Skills Guide

Skills are reusable context packages that extend Tron's capabilities. Each skill is a folder containing a `SKILL.md` file with optional YAML frontmatter and supporting files.

## Quick Start

Create a skill in `~/.tron/skills/` (global) or `.tron/skills/` (project):

```bash
mkdir -p ~/.tron/skills/my-skill
cat > ~/.tron/skills/my-skill/SKILL.md << 'EOF'
---
autoInject: false
tags: [example]
---
This skill helps with X.

## Guidelines

- Do Y when Z happens
- Always prefer A over B
EOF
```

Reference it in prompts with `@my-skill`:

```
@my-skill Help me refactor this function
```

---

## Skill Locations

| Location | Path | Scope | Precedence |
|----------|------|-------|------------|
| **Global** | `~/.tron/skills/` | All projects | Lower |
| **Project** | `.tron/skills/` | Current project only | Higher |

Project skills override global skills with the same name.

---

## Frontmatter Reference

Frontmatter is YAML metadata at the top of `SKILL.md`, delimited by `---`:

```yaml
---
autoInject: false
version: "1.0.0"
tools:
  - Read
  - Edit
  - Bash
tags:
  - coding
  - standards
---
```

### `autoInject`

**Type:** `boolean`
**Default:** `false`

When `true`, the skill is automatically included in every prompt without explicit `@reference`. Use for project rules, coding standards, and always-on guidelines.

```yaml
---
autoInject: true
---
```

**Use cases:**
- Project coding conventions
- Security guidelines
- Architectural rules
- Team preferences

**Caution:** Auto-inject skills consume context tokens on every request. Keep them focused and concise.

---

### `version`

**Type:** `string`
**Default:** none

Semantic version for tracking skill changes. Useful for shared skills.

```yaml
---
version: "2.1.0"
---
```

---

### `tools`

**Type:** `string[]`
**Default:** `[]`

Tools this skill is designed to work with. Informational—helps users understand the skill's scope.

```yaml
---
tools:
  - Read
  - Edit
  - Bash
  - WebFetch
---
```

**Supported formats:**

```yaml
# Multi-line array
tools:
  - Read
  - Edit

# Inline array
tools: [Read, Edit, Bash]
```

---

### `tags`

**Type:** `string[]`
**Default:** `[]`

Tags for categorization, filtering, and discovery.

```yaml
---
tags:
  - typescript
  - testing
  - best-practices
---
```

**Common tags:**
- Language: `typescript`, `python`, `rust`, `go`
- Domain: `frontend`, `backend`, `devops`, `security`
- Type: `rules`, `workflow`, `reference`, `template`
- Quality: `coding-standards`, `testing`, `documentation`

---

## Writing Skill Content

The skill content (everything after frontmatter) is injected into the prompt wrapped in XML:

```xml
<skills>
<skill name="my-skill">
[Your SKILL.md content here]
</skill>
</skills>
```

### Content Principles

**1. Be Directive**

Write instructions, not suggestions. The agent follows directives.

```markdown
<!-- Good: Clear directive -->
Always use TypeScript strict mode.

<!-- Bad: Passive suggestion -->
It might be good to consider using TypeScript strict mode.
```

**2. Be Specific**

Concrete examples beat abstract rules.

```markdown
<!-- Good: Specific pattern -->
Format imports in this order:
1. Node built-ins (`fs`, `path`)
2. External packages (`lodash`, `express`)
3. Internal modules (`./utils`, `../config`)

<!-- Bad: Vague guidance -->
Keep imports organized.
```

**3. Be Concise**

Every token costs context. Cut ruthlessly.

```markdown
<!-- Good: Dense instruction -->
Use `bun:sqlite` for database operations. Prefer prepared statements.

<!-- Bad: Verbose explanation -->
When you need to interact with a SQLite database, you should
consider using the bun:sqlite module because it provides better
performance compared to other options. Additionally, it would
be beneficial to use prepared statements for security.
```

**4. Use Structure**

Headers, lists, and code blocks improve comprehension.

```markdown
## Error Handling

- Catch specific exceptions, not generic `Error`
- Log with context: `logger.error({ userId, action }, 'Failed')`
- Return typed errors, don't throw across boundaries

## Naming

| Type | Convention | Example |
|------|------------|---------|
| Functions | camelCase | `getUserById` |
| Classes | PascalCase | `UserService` |
| Constants | UPPER_SNAKE | `MAX_RETRIES` |
```

---

## Skill Structure

### Basic Skill

```
my-skill/
└── SKILL.md
```

### Skill with Supporting Files

```
api-client/
├── SKILL.md           # Main instructions
├── template.ts        # Code template to reference
├── examples/
│   ├── get.ts
│   └── post.ts
└── schema.json        # API schema
```

Reference supporting files in your skill content:

```markdown
## Template

Use the pattern in `template.ts` when creating new API clients.

## Examples

See `examples/get.ts` for GET requests and `examples/post.ts` for POST.
```

The `additionalFiles` array in skill metadata lists these files for the agent.

---

## Writing Style Guide

### Tone

- **Authoritative**: State rules as facts, not opinions
- **Direct**: Use imperative mood ("Use X", "Avoid Y")
- **Practical**: Focus on actions, not theory

### Format Conventions

**Headers:** Use for logical sections. H2 (`##`) for main topics, H3 (`###`) for subtopics.

```markdown
## Database Access

### Queries

Use parameterized queries exclusively.

### Transactions

Wrap multi-step operations in transactions.
```

**Lists:** Use for rules, steps, and options.

```markdown
When handling errors:
- Log the full error with stack trace
- Return a user-friendly message
- Never expose internal details
```

**Code Blocks:** Use for examples, patterns, and templates.

````markdown
## Pattern: Service Class

```typescript
class UserService {
  constructor(private db: Database) {}

  async getById(id: string): Promise<User | null> {
    return this.db.query('SELECT * FROM users WHERE id = ?', [id]);
  }
}
```
````

**Tables:** Use for mappings, comparisons, and reference data.

```markdown
| Status | Meaning | Action |
|--------|---------|--------|
| 200 | Success | Return data |
| 404 | Not found | Return null |
| 500 | Error | Throw, log |
```

### Description Line

The first non-header, non-empty line becomes the skill description shown in the UI. Make it count.

```markdown
---
autoInject: false
---
Guidelines for writing clean, maintainable TypeScript code.

## Rules
...
```

The description "Guidelines for writing clean, maintainable TypeScript code." appears in skill listings.

---

## Examples

### Auto-Inject Rule: Coding Standards

```markdown
---
autoInject: true
version: "1.0.0"
tags: [rules, typescript]
---
TypeScript coding standards for this project.

## Strict Mode

All files must have `strict: true`. No `any` types except at boundaries.

## Imports

1. Node built-ins
2. External packages
3. Internal absolute (`@/`)
4. Internal relative (`./`)

## Error Handling

- Use `Result<T, E>` for recoverable errors
- Throw only for programmer errors
- Always include context in error messages

## Naming

- Files: `kebab-case.ts`
- Functions: `camelCase`
- Classes: `PascalCase`
- Constants: `UPPER_SNAKE_CASE`
```

### On-Demand Skill: API Design

```markdown
---
autoInject: false
version: "2.0.0"
tools: [Edit, Write]
tags: [api, rest, design]
---
REST API design guidelines for this project.

## Endpoints

```
GET    /resources          List all
GET    /resources/:id      Get one
POST   /resources          Create
PUT    /resources/:id      Replace
PATCH  /resources/:id      Update
DELETE /resources/:id      Remove
```

## Response Format

```json
{
  "data": { ... },
  "meta": { "page": 1, "total": 100 }
}
```

## Error Response

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Email is required",
    "details": { "field": "email" }
  }
}
```

## Status Codes

| Code | Use |
|------|-----|
| 200 | Success with body |
| 201 | Created |
| 204 | Success, no body |
| 400 | Client error |
| 401 | Not authenticated |
| 403 | Not authorized |
| 404 | Not found |
| 500 | Server error |
```

### On-Demand Skill: Database Migrations

```markdown
---
autoInject: false
tools: [Bash, Edit, Write]
tags: [database, migrations]
---
Database migration workflow and conventions.

## Creating Migrations

```bash
bun run migrate:create <name>
```

Names should be descriptive: `add-user-email-index`, `create-orders-table`.

## Migration Structure

```typescript
import { Migration } from '@/db';

export const up: Migration = async (db) => {
  await db.exec(`
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      created_at INTEGER DEFAULT (unixepoch())
    )
  `);
};

export const down: Migration = async (db) => {
  await db.exec('DROP TABLE users');
};
```

## Rules

- Migrations are immutable once deployed
- Always provide `down` for rollback
- Test both directions locally
- Use transactions for multi-statement migrations
```

---

## Referencing Skills

### Explicit Reference

Use `@skill-name` anywhere in your prompt:

```
@api-design Create a new endpoint for user preferences
```

Multiple skills:

```
@typescript-rules @testing Help me write tests for the UserService
```

### Reference Behavior

1. References are extracted from the prompt
2. Skill content is loaded and wrapped in `<skills>` XML
3. References are removed from the user message
4. Skills are prepended to the context

The prompt:

```
@api-design Create a GET endpoint for orders
```

Becomes:

```xml
<skills>
<skill name="api-design">
[Full api-design SKILL.md content]
</skill>
</skills>

Create a GET endpoint for orders
```

### Reference Syntax

Valid references:
- `@my-skill` — simple name
- `@my-skill-name` — with hyphens
- `@my_skill_name` — with underscores
- `@mySkillName` — camelCase

Invalid (ignored):
- `user@example.com` — email addresses
- `` `@reference` `` — inside inline code
- Code blocks — inside triple backticks

---

## Best Practices

### Do

- **Keep auto-inject skills small** — they're included in every request
- **Use tags consistently** — enables filtering and discovery
- **Include examples** — concrete patterns are clearer than abstract rules
- **Version shared skills** — track changes across projects
- **Test your skills** — verify they produce expected behavior

### Don't

- **Don't repeat framework docs** — link to them instead
- **Don't include secrets** — skills are plain text
- **Don't over-engineer** — start simple, add complexity as needed
- **Don't duplicate** — one skill per concept
- **Don't be vague** — unclear instructions produce inconsistent results

---

## Skill Discovery

Skills are scanned at startup and can be refreshed via RPC:

```typescript
// List all skills
const skills = await rpcClient.listSkills();

// Get a specific skill
const skill = await rpcClient.getSkill('api-design');

// Refresh cache after adding new skills
await rpcClient.refreshSkills();
```

In the iOS app, skills appear in:
- **InputBar** — Attachment menu → Add Skill
- **Context Manager** — System & Tools section (auto-inject), Referenced Skills section (explicit)

---

## Troubleshooting

### Skill not found

1. Check the folder name matches the reference (case-sensitive)
2. Verify `SKILL.md` exists in the folder
3. Run skill refresh to reload cache
4. Check for parse errors in frontmatter

### Skill not auto-injecting

1. Verify `autoInject: true` in frontmatter
2. Check frontmatter syntax (proper `---` delimiters)
3. Ensure skill is in correct location (`~/.tron/skills/` or `.tron/skills/`)

### Content not appearing correctly

1. Check for unclosed code blocks
2. Verify frontmatter YAML is valid
3. Ensure file is UTF-8 encoded
4. Check file size (max 100KB)

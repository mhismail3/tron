---
name: Package Management
description: Manage dependencies with npm, cargo, pip, and brew
version: "1.0.0"
tags: [packages, dependencies]
allowedTools: [Bash]
display:
  label: Packages
  icon: shippingbox
  color: "#8B5CF6"
---

# Package Management

Manage project dependencies with the appropriate package manager.
Always include `skill: "packages"` in your Bash call when using this skill.

## Manager Detection

| File | Manager | Install | Add |
|------|---------|---------|-----|
| `Cargo.toml` | cargo | `cargo build` | `cargo add crate_name` |
| `package.json` + `package-lock.json` | npm | `npm install` | `npm install pkg` |
| `package.json` + `yarn.lock` | yarn | `yarn install` | `yarn add pkg` |
| `package.json` + `pnpm-lock.yaml` | pnpm | `pnpm install` | `pnpm add pkg` |
| `pyproject.toml` / `requirements.txt` | pip/uv | `pip install -r requirements.txt` | `pip install pkg` |
| `go.mod` | go modules | `go mod download` | `go get pkg` |
| `Gemfile` | bundler | `bundle install` | `bundle add gem` |

## Common Operations

```bash
# Install all dependencies
npm install          # Node.js
cargo build          # Rust (builds + fetches deps)
pip install -r requirements.txt  # Python

# Add a dependency
npm install lodash
cargo add serde --features derive
pip install requests

# Remove a dependency
npm uninstall lodash
cargo remove serde

# Update dependencies
npm update
cargo update
pip install --upgrade pkg

# List installed
npm list --depth=0
cargo tree --depth=1
pip list

# Audit for vulnerabilities
npm audit
cargo audit          # requires cargo-audit
pip-audit            # requires pip-audit
```

## Lockfile Handling

- **Never delete lockfiles** (`package-lock.json`, `Cargo.lock`, `yarn.lock`, etc.) — they ensure reproducible builds
- **Commit lockfiles** to version control
- **If lockfile conflicts arise** during merge, re-run the install command to regenerate rather than manually editing
- **If a lockfile is stale**, run the install command to update it

## Safe Practices

- Check what a package does before installing (especially for npm where supply chain attacks are common)
- Prefer exact versions or narrow ranges for production dependencies
- Run `npm audit` or equivalent after adding new dependencies
- Use `--save-dev` / `--dev` for development-only dependencies

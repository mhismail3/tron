---
name: Testing
description: Discover and run tests across frameworks
version: "1.0.0"
tags: [testing, ci]
allowedTools: [Bash]
display:
  label: Testing
  icon: checkmark.circle
  color: "#22C55E"
guards:
  maxOutputLines: 1000
---

# Testing

Discover and run tests using the appropriate framework for the project.
Always include `skill: "testing"` in your Bash call when using this skill.

## Framework Detection

Check for test configuration to determine the framework:

| File | Framework | Run Command |
|------|-----------|-------------|
| `Cargo.toml` | Rust (cargo test) | `cargo test` |
| `package.json` + jest | Jest | `npx jest` or `npm test` |
| `package.json` + vitest | Vitest | `npx vitest run` |
| `pyproject.toml` / `pytest.ini` | pytest | `pytest` |
| `go.mod` | Go | `go test ./...` |
| `build.gradle` / `pom.xml` | JUnit | `./gradlew test` / `mvn test` |

## Running Tests

```bash
# Rust
cargo test                       # All tests
cargo test -- --quiet            # Quiet output (pass/fail only)
cargo test test_name             # Run specific test
cargo test module::              # Run tests in a module
cargo test -- --nocapture        # Show stdout from tests

# JavaScript/TypeScript
npx jest                         # All tests
npx jest --testPathPattern=file  # Specific file
npx jest --watch                 # Watch mode (interactive)
npm test                         # Project-configured test command

# Python
pytest                           # All tests
pytest path/to/test.py           # Specific file
pytest -k "test_name"            # By name pattern
pytest -x                        # Stop on first failure
pytest -v                        # Verbose output

# Go
go test ./...                    # All packages
go test ./pkg/...                # Specific package subtree
go test -run TestName ./pkg      # Specific test
go test -v ./...                 # Verbose
```

## Test Patterns

- **Run full suite first** to establish baseline
- **Run specific tests** when iterating on a fix
- **Use quiet/summary mode** for large suites to avoid overwhelming output
- **Check exit code** — non-zero means failures
- **Read failure messages carefully** — they usually point directly to the issue

## Interpreting Results

- Look for **FAILED** or **FAIL** lines first
- Check **assertion messages** for expected vs actual values
- For Rust: `cargo test -- --quiet` shows only failures
- For pytest: `-x` stops at first failure, `--tb=short` for compact tracebacks

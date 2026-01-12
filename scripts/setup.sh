#!/usr/bin/env bash
#
# Tron Agent Setup Script
#
# This script sets up the Tron agent environment, including:
# - Creating necessary directories
# - Installing dependencies
# - Building the project
# - Setting up initial configuration
#
# Usage: ./scripts/setup.sh [--dev]
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Flags
DEV_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dev)
            DEV_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dev]"
            echo ""
            echo "Options:"
            echo "  --dev    Install development dependencies"
            echo "  -h       Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

log() {
    echo -e "${BLUE}[tron]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}!${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check Node.js
    if ! command -v node &> /dev/null; then
        error "Node.js is not installed. Please install Node.js 20+ first."
    fi

    NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -lt 20 ]; then
        error "Node.js version 20+ is required. Current version: $(node -v)"
    fi
    success "Node.js $(node -v) found"

    # Check or install Bun
    if ! command -v bun &> /dev/null; then
        log "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export PATH="$HOME/.bun/bin:$PATH"
        success "Bun installed"
    else
        success "Bun $(bun --version) found"
    fi

    # Check git (optional but recommended)
    if command -v git &> /dev/null; then
        success "git $(git --version | cut -d' ' -f3) found"
    else
        warn "git not found (optional but recommended)"
    fi
}

# Create directory structure
create_directories() {
    log "Creating directory structure..."

    mkdir -p "$TRON_HOME"/{logs,sessions,memory,tasks,notes,inbox,skills,hooks}
    mkdir -p "$TRON_HOME"/memory/{handoffs,learnings}
    mkdir -p "$TRON_HOME"/inbox/processed

    success "Created $TRON_HOME directory structure"
}

# Create default configuration files
create_config() {
    log "Creating configuration files..."

    # Default settings
    if [ ! -f "$TRON_HOME/settings.json" ]; then
        cat > "$TRON_HOME/settings.json" << 'EOF'
{
  "defaultModel": "claude-sonnet-4-20250514",
  "serverPort": 3847,
  "logging": {
    "level": "info",
    "maxFiles": 10,
    "maxSize": "10M"
  },
  "session": {
    "idleTimeout": 3600000,
    "autoSave": true,
    "autoSaveInterval": 30000
  },
  "memory": {
    "ledgerAutoSave": true,
    "handoffOnCompact": true,
    "retentionDays": 90
  },
  "hooks": {
    "timeout": 30000,
    "enabled": true
  }
}
EOF
        success "Created settings.json"
    else
        warn "settings.json already exists, skipping"
    fi

    # Default AGENTS.md (global context)
    if [ ! -f "$TRON_HOME/AGENTS.md" ]; then
        cat > "$TRON_HOME/AGENTS.md" << 'EOF'
# Global Agent Context

This file provides global instructions that apply to all Tron sessions.

## General Guidelines

- Be concise and direct in responses
- Follow the project's coding conventions
- Write tests for new functionality
- Document significant changes

## Memory Usage

- Keep the ledger updated with current focus
- Generate handoffs before context compaction
- Record key decisions with reasoning

## Tool Usage

- Prefer read over grep for small files
- Use edit for precise modifications
- Always verify paths exist before writing
EOF
        success "Created AGENTS.md"
    else
        warn "AGENTS.md already exists, skipping"
    fi

    # Models registry
    if [ ! -f "$TRON_HOME/models.json" ]; then
        cat > "$TRON_HOME/models.json" << 'EOF'
{
  "models": {
    "claude-sonnet-4-20250514": {
      "provider": "anthropic",
      "contextWindow": 200000,
      "maxOutput": 8192,
      "costPer1kInput": 0.003,
      "costPer1kOutput": 0.015
    },
    "claude-opus-4-20250514": {
      "provider": "anthropic",
      "contextWindow": 200000,
      "maxOutput": 8192,
      "costPer1kInput": 0.015,
      "costPer1kOutput": 0.075
    },
    "gpt-4o": {
      "provider": "openai",
      "contextWindow": 128000,
      "maxOutput": 4096,
      "costPer1kInput": 0.005,
      "costPer1kOutput": 0.015
    },
    "gemini-1.5-pro": {
      "provider": "google",
      "contextWindow": 1000000,
      "maxOutput": 8192,
      "costPer1kInput": 0.00125,
      "costPer1kOutput": 0.005
    }
  }
}
EOF
        success "Created models.json"
    else
        warn "models.json already exists, skipping"
    fi
}

# Install dependencies
install_dependencies() {
    log "Installing dependencies..."

    cd "$PROJECT_DIR"

    # Install with bun
    bun install

    # Note: Bun has built-in SQLite support via bun:sqlite
    # Native dependencies like better-sqlite3 and esbuild work automatically with Bun

    success "Dependencies installed"
}

# Build the project
build_project() {
    log "Building project..."

    cd "$PROJECT_DIR"

    # Build all packages in order using the workspace build script
    ./scripts/build-workspace.sh

    success "Project built successfully"
}

# Run tests (optional)
run_tests() {
    if [ "$DEV_MODE" = true ]; then
        log "Running tests..."

        cd "$PROJECT_DIR"
        if bun test; then
            success "All tests passed"
        else
            warn "Some tests failed (continuing anyway)"
        fi
    fi
}

# Create default skills
create_default_skills() {
    log "Creating default skills..."

    # Commit skill
    mkdir -p "$TRON_HOME/skills/commit"
    if [ ! -f "$TRON_HOME/skills/commit/SKILL.md" ]; then
        cat > "$TRON_HOME/skills/commit/SKILL.md" << 'EOF'
---
name: commit
description: Create a git commit with a well-formatted message
arguments:
  - name: message
    description: Optional commit message (will be generated if not provided)
    required: false
---

# Commit Skill

Create a git commit following conventional commit format.

## Instructions

1. Run `git status` to see changes
2. Run `git diff --staged` to understand what's being committed
3. Generate a commit message following this format:
   - type(scope): description
   - Types: feat, fix, docs, style, refactor, test, chore
4. Run `git commit -m "..."` with the message
5. Report the commit hash
EOF
        success "Created commit skill"
    fi

    # Handoff skill
    mkdir -p "$TRON_HOME/skills/handoff"
    if [ ! -f "$TRON_HOME/skills/handoff/SKILL.md" ]; then
        cat > "$TRON_HOME/skills/handoff/SKILL.md" << 'EOF'
---
name: handoff
description: Generate a handoff document for session continuity
arguments: []
---

# Handoff Skill

Generate a handoff document summarizing the current session.

## Instructions

1. Review the session's conversation history
2. Identify:
   - What was accomplished
   - Current state of the work
   - Any blockers or issues
   - Recommended next steps
   - Patterns or learnings discovered
3. Create a handoff document with these sections
4. Save to the handoffs directory
EOF
        success "Created handoff skill"
    fi

    # Ledger skill
    mkdir -p "$TRON_HOME/skills/ledger"
    if [ ! -f "$TRON_HOME/skills/ledger/SKILL.md" ]; then
        cat > "$TRON_HOME/skills/ledger/SKILL.md" << 'EOF'
---
name: ledger
description: Update the session continuity ledger
arguments:
  - name: section
    description: Ledger section to update (goal, now, next, done, decision)
    required: false
---

# Ledger Skill

Update the continuity ledger with current session state.

## Instructions

1. Read the current ledger if it exists
2. Update the requested section (or all if not specified)
3. Preserve existing content in other sections
4. Save the updated ledger

## Sections

- **Goal**: Overall objective for this work
- **Now**: Current focus/task
- **Next**: Upcoming tasks (as checklist)
- **Done**: Completed tasks (as checklist)
- **Decisions**: Key decisions made with reasoning
EOF
        success "Created ledger skill"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    Tron Setup Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Data directory: $TRON_HOME"
    echo "  Project path:   $PROJECT_DIR"
    echo ""
    echo "  Next steps:"
    echo "    1. Configure authentication:"
    echo "       - Set ANTHROPIC_API_KEY for API access, or"
    echo "       - Run 'tron login' for Claude Max OAuth"
    echo ""
    echo "    2. Start the server:"
    echo "       bun run server:start"
    echo ""
    echo "    3. Launch the TUI:"
    echo "       bun run dev:tui"
    echo ""
    echo "  Note: Bun has built-in SQLite (bun:sqlite) which is 3-6x faster"
    echo "        than better-sqlite3 for database operations."
    echo ""
    echo "    4. (Optional) Install as a service:"
    echo "       ./scripts/install-service.sh"
    echo ""
}

# Main execution
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                      Tron Agent Setup                        ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites
    create_directories
    create_config
    install_dependencies
    build_project
    run_tests
    create_default_skills
    print_summary
}

main "$@"

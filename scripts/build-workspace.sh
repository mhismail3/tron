#!/usr/bin/env bash
#
# Build all workspace packages in dependency order
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Ensure Bun is in PATH
export PATH="$HOME/.bun/bin:$PATH"

# Build packages in dependency order
echo "Building @tron/core..."
(cd "$PROJECT_DIR/packages/core" && bun run build)

echo "Building @tron/server..."
(cd "$PROJECT_DIR/packages/server" && bun run build)

echo "Building @tron/tui..."
(cd "$PROJECT_DIR/packages/tui" && bun run build)

echo "Building @tron/chat-web..."
(cd "$PROJECT_DIR/packages/chat-web" && bun run build)

echo "✓ All packages built successfully"

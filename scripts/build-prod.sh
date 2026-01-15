#!/bin/bash
#
# Build production bundle for Tron server
#
# Creates a single self-contained JS file with all dependencies bundled.
# External deps (native modules) are copied separately.
#
# Output:
#   dist/prod/tron-server.mjs     - Main bundle
#   dist/prod/node_modules/       - External native dependencies
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "Building production bundle..."

# First build TypeScript
echo "  Compiling TypeScript..."
bun run build

# Create clean output directory
rm -rf dist/prod
mkdir -p dist/prod/node_modules

# Bundle server with all dependencies into single file
# External: native modules that can't be bundled
echo "  Bundling with esbuild..."

# Create banner to polyfill import.meta.url for CJS
BANNER='const _importMetaUrl = require("url").pathToFileURL(__filename).href;'

# Name the output index.js so the server's argv[1] check passes
# External: native modules that require .node binaries
./node_modules/.bin/esbuild packages/server/dist/index.js \
  --bundle \
  --platform=node \
  --target=node20 \
  --format=cjs \
  --outfile=dist/prod/index.js \
  --external:playwright-core \
  --external:better-sqlite3 \
  --metafile=dist/prod/meta.json \
  --banner:js="$BANNER" \
  --define:import.meta.url=_importMetaUrl \
  --minify

# Copy runtime assets (prompts, etc.)
echo "  Copying runtime assets..."
if [ -d "packages/core/dist/providers/prompts" ]; then
    cp -r packages/core/dist/providers/prompts dist/prod/
    echo "    ✓ prompts"
fi

# Copy external native dependencies
echo "  Copying external dependencies..."

# Find playwright-core in bun's package cache or regular node_modules
PLAYWRIGHT_PATH=""
if [ -d "node_modules/playwright-core" ]; then
    PLAYWRIGHT_PATH="node_modules/playwright-core"
elif [ -d "node_modules/.bun" ]; then
    # Find in bun's cache
    PLAYWRIGHT_PATH=$(find node_modules/.bun -type d -name "playwright-core" | grep "node_modules/playwright-core$" | head -1)
fi

if [ -n "$PLAYWRIGHT_PATH" ] && [ -d "$PLAYWRIGHT_PATH" ]; then
    cp -r "$PLAYWRIGHT_PATH" dist/prod/node_modules/
    echo "    ✓ playwright-core"
else
    echo "    ⚠ playwright-core not found (browser features may not work)"
fi

# Find and copy better-sqlite3 (native SQLite bindings)
SQLITE_PATH=""
if [ -d "node_modules/better-sqlite3" ]; then
    SQLITE_PATH="node_modules/better-sqlite3"
elif [ -d "node_modules/.bun" ]; then
    SQLITE_PATH=$(find node_modules/.bun -type d -name "better-sqlite3" | grep "node_modules/better-sqlite3$" | head -1)
fi

if [ -n "$SQLITE_PATH" ] && [ -d "$SQLITE_PATH" ]; then
    cp -r "$SQLITE_PATH" dist/prod/node_modules/
    echo "    ✓ better-sqlite3"
else
    echo "    ⚠ better-sqlite3 not found (database features may not work)"
fi

# Also copy bindings module (needed by better-sqlite3)
BINDINGS_PATH=""
if [ -d "node_modules/bindings" ]; then
    BINDINGS_PATH="node_modules/bindings"
elif [ -d "node_modules/.bun" ]; then
    BINDINGS_PATH=$(find node_modules/.bun -type d -name "bindings" | grep "node_modules/bindings$" | head -1)
fi

if [ -n "$BINDINGS_PATH" ] && [ -d "$BINDINGS_PATH" ]; then
    cp -r "$BINDINGS_PATH" dist/prod/node_modules/
    echo "    ✓ bindings"
fi

# Copy file-uri-to-path (dependency of bindings)
FILEURI_PATH=""
if [ -d "node_modules/file-uri-to-path" ]; then
    FILEURI_PATH="node_modules/file-uri-to-path"
elif [ -d "node_modules/.bun" ]; then
    FILEURI_PATH=$(find node_modules/.bun -type d -name "file-uri-to-path" | grep "node_modules/file-uri-to-path$" | head -1)
fi

if [ -n "$FILEURI_PATH" ] && [ -d "$FILEURI_PATH" ]; then
    cp -r "$FILEURI_PATH" dist/prod/node_modules/
    echo "    ✓ file-uri-to-path"
fi

# Create a minimal package.json for the production bundle
cat > dist/prod/package.json << 'EOF'
{
  "name": "tron-server-prod",
  "version": "1.0.0",
  "main": "index.js"
}
EOF

# Show bundle info
BUNDLE_SIZE=$(ls -lh dist/prod/index.js | awk '{print $5}')
TOTAL_SIZE=$(du -sh dist/prod | awk '{print $1}')
echo ""
echo "✓ Production build complete"
echo "  Bundle:  dist/prod/index.js ($BUNDLE_SIZE)"
echo "  Total:   dist/prod/ ($TOTAL_SIZE)"
echo ""

#!/bin/bash
# Rebuild the historical fixture using the same real RuntimeRegistry driver.
set -eu
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <read-only-pi-subagents-0.59.0-directory> <private-evidence-directory>" >&2
  exit 2
fi
repo=$(git rev-parse --show-toplevel)
node --version
expected="v$(tr -d v < "$repo/.node-version")"
if [ "$(node --version)" != "$expected" ]; then echo "Use the repository's pinned Node $expected" >&2; exit 2; fi
package=$(cd "$1" && pwd -P)
evidence=$(mkdir -p "$2" && cd "$2" && pwd -P)
root=$(mktemp -d "$evidence/parity-env.XXXXXX")
cleanup() {
  git -C "$repo" worktree remove --force "$root/old"
  git -C "$repo" worktree prune
  rm -rf "$root"
}
trap cleanup EXIT
mkdir "$root/home" "$root/tmp"
git -C "$repo" worktree add --detach "$root/old" 1dc07c210
cd "$root/old/packages/gateway"
env -i PATH="$PATH" HOME="$root/home" TMPDIR="$root/tmp" npm ci --no-audit --no-fund
# The read-only package has no node_modules. Install its exact declared runtime
# dependencies beside the historical SDK, never inside the source installation.
env -i PATH="$PATH" HOME="$root/home" TMPDIR="$root/tmp" npm install --no-save --no-audit --no-fund jiti@2.7.0 acorn@8.18.0 yaml@2.8.3 typebox@1.1.38
cp "$repo/packages/gateway/src/sessions/subagent-parity.integration.test.ts" src/sessions/
cp "$repo/packages/gateway/test-support/fixture-process-owner.mjs" test-support/
env -i PATH="$PATH" HOME="$root/home" TMPDIR="$root/tmp" PI_SKIP_VERSION_CHECK=1 \
  TRON_PARITY_LEG=old TRON_PARITY_OLD_PACKAGE="$package" TRON_PARITY_REPORT="$evidence/parity-old.json" \
  TRON_PARITY_BASELINE_OUTPUT="$repo/packages/gateway/test-support/subagent-parity-old.json" \
  npx vitest run src/sessions/subagent-parity.integration.test.ts --maxWorkers=2

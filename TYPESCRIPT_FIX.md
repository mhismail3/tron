# TypeScript Declaration Generation Fix

## Problem

TypeScript was failing to find declaration files for workspace packages:

```
error TS7016: Could not find a declaration file for module '@tron/core'.
'/Users/moose/Downloads/projects/tron/packages/core/dist/index.js' implicitly has an 'any' type.
```

This affected `@tron/server`, `@tron/tui`, and `@tron/chat-web` when importing from `@tron/core`.

## Root Causes

### 1. Path Mappings Pointing to Source
The root `tsconfig.json` had path mappings that pointed to source directories:

```json
"paths": {
  "@tron/core": ["packages/core/src"],  // ❌ Wrong - points to src during build
  ...
}
```

During build time, TypeScript would resolve `@tron/core` to the **source** directory, but the `.d.ts` files were in the **dist** directory.

### 2. Missing Declaration Flags
Child package `tsconfig` files inherited from root but didn't explicitly enable declaration generation:

```json
// packages/server/tsconfig.json - BEFORE
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "rootDir": "src",
    "outDir": "dist"
    // ❌ Missing: declaration, declarationMap, composite
  }
}
```

### 3. Stale Incremental Build Cache
TypeScript's `.tsbuildinfo` files contained stale state from previous configurations. Even after fixing the config, declarations wouldn't generate until these were deleted.

## Solutions Applied

### 1. Removed Path Mappings
**File:** `tsconfig.json`

```json
{
  "compilerOptions": {
    "baseUrl": "."
    // ✅ Removed "paths" - let Node module resolution handle it
  }
}
```

**Why:** Node's module resolution through `package.json` exports is more reliable for workspaces. It automatically resolves to the built `dist/` directory.

### 2. Added Explicit Declaration Flags
**Files:** `packages/*/tsconfig*.json`

```json
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "rootDir": "./src",
    "outDir": "./dist",
    "declaration": true,        // ✅ Generate .d.ts files
    "declarationMap": true,     // ✅ Generate .d.ts.map for IDE navigation
    "composite": true           // ✅ Enable project references
  }
}
```

### 3. Added Project References
**Files:** `packages/server/tsconfig.json`, `packages/tui/tsconfig.build.json`

```json
{
  "references": [
    { "path": "../core" }  // ✅ Reference dependency packages
  ]
}
```

**Why:** Project references enable proper TypeScript workspace builds and incremental compilation.

### 4. Clean Stale Build Files
**Command:** `rm -f packages/*/tsconfig*.tsbuildinfo`

Updated the `clean` script to automatically remove these:

```json
"clean": "rm -rf packages/*/dist packages/*/tsconfig*.tsbuildinfo ..."
```

## Verification

After fixes, all packages generate declarations:

```bash
bun run build

# Results:
# Core declarations: 85 files
# Server declarations: 13 files
# TUI declarations: 33 files
```

No more TypeScript errors! ✅

## Key Learnings

1. **Don't use path mappings in monorepos** when source and dist differ. Let Node resolve workspaces.

2. **Stale `.tsbuildinfo` files** can prevent new declarations from generating. Always clean these when config changes.

3. **Child configs need explicit flags** - inheritance doesn't always work as expected with `declaration` flags.

4. **Project references are essential** for TypeScript workspace builds to work correctly.

5. **Use `tsc --listEmittedFiles`** to debug why files aren't generating.

## Testing

To verify the fix works on a clean machine:

```bash
# Clean everything
bun run clean

# Fresh install
bun install

# Build - should complete without errors
bun run build

# Verify declarations exist
find packages/*/dist -name "*.d.ts" | wc -l
# Should show: 131+ files
```

## Files Changed

- `tsconfig.json` - Removed path mappings
- `packages/core/tsconfig.build.json` - Added declaration flags
- `packages/server/tsconfig.json` - Added declaration flags + references
- `packages/tui/tsconfig.build.json` - Added declaration flags + references
- `package.json` - Updated clean script

All changes committed to git.

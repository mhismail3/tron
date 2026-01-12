# Browser Tool Fixes

## Issues Identified and Fixed

### 1. "Cannot read properties of undefined (reading 'snapshot')" Error
**Location**: `packages/server/src/browser/browser-service.ts:327`

**Problem**: The accessibility API was being called immediately after page navigation without checking if it was available or if the page had fully loaded.

**Fix**:
- Added `waitForLoadState('domcontentloaded')` before attempting to access accessibility API
- Added 100ms delay to ensure accessibility tree is populated
- Added null checks for both `accessibility` object and `snapshot()` return value
- Return descriptive errors instead of throwing exceptions

**Code Changes**:
```typescript
// Wait for page to be ready - accessibility API may not be available immediately
await session.page.waitForLoadState('domcontentloaded', { timeout: 5000 }).catch(() => {});

// Small delay to ensure accessibility tree is populated
await session.page.waitForTimeout(100);

const accessibility = (session.page as any).accessibility;
if (!accessibility) {
  return {
    success: false,
    error: 'Accessibility API not available on this page',
  };
}

const snapshot = await accessibility.snapshot();
if (!snapshot) {
  return {
    success: false,
    error: 'Failed to capture accessibility snapshot - page may not be fully loaded',
  };
}
```

### 2. iOS App Not Displaying Browser Tool Properly
**Location**: `packages/ios-app/Sources/Views/ToolResultViewers.swift`

**Problem**: The `ToolResultRouter` didn't have a case for the "browser" tool, so it fell through to the default case which showed a generic gear icon without proper formatting.

**Fix**:
- Added "browser" case to `toolIconConfig` with globe icon and blue color
- Added "browser" case to `displayToolName`
- Added "browser" case to `toolDetail` extraction
- Added "browser" case to `resultViewer` routing
- Created `extractBrowserAction()` helper to parse browser arguments
- Created `BrowserResultViewer` component for displaying browser results

**Visual Improvements**:
- Browser tools now show with 🌐 globe icon in blue color
- Tool detail shows action type and target (e.g., "navigate: https://example.com", "click: button.submit")
- Results are displayed in a clean, collapsible format

### 3. Parallel Execution Causing Race Conditions
**Location**: `packages/core/src/tools/browser.ts`

**Problem**: Claude was calling multiple browser tools in parallel (navigate + snapshot + screenshot all at once), causing race conditions where snapshot was called before the page finished loading from navigate.

**Fix**:
Updated the tool description to explicitly guide Claude to execute browser actions sequentially:

```typescript
IMPORTANT: Execute browser actions ONE AT A TIME sequentially - wait for each action to complete before starting the next. Do NOT call multiple browser tools in parallel as this causes race conditions.

Recommended workflow:
1. navigate to URL → wait for result
2. snapshot to get page structure → wait for result
3. screenshot to see visual state → wait for result
4. interact (click/fill/etc.) → wait for result
5. repeat as needed
```

Also reordered the action list to put the most common sequence first (navigate, snapshot, screenshot, then interactions).

### 4. Agent Getting Wrong Information
**Root Cause**: The snapshot failures from issue #1 meant the agent wasn't receiving proper accessibility tree data, causing it to work with incomplete or missing information about the page structure.

**Fix**: Resolved by fixing issue #1 - with proper snapshot data, the agent now has accurate information about page structure and can interact correctly.

## Testing Recommendations

1. **Test snapshot after navigation**:
   - Navigate to various websites
   - Call snapshot immediately after
   - Verify accessibility tree data is returned

2. **Test sequential execution**:
   - Ask Claude to browse a website
   - Monitor the logs to ensure tools execute one at a time
   - Verify no "spinning" or stuck states

3. **Test iOS rendering**:
   - Run the iOS app
   - Use browser tools
   - Verify tool calls show with proper icons and details

4. **Test various browser actions**:
   - navigate, snapshot, screenshot
   - click, fill, type, select
   - scroll, wait
   - Verify all actions complete successfully

## Files Modified

1. `packages/server/src/browser/browser-service.ts` - Fixed snapshot race condition
2. `packages/core/src/tools/browser.ts` - Improved tool description for sequential execution
3. `packages/ios-app/Sources/Views/ToolResultViewers.swift` - Added browser tool rendering

## Known Limitations

- Accessibility API may not work on all websites (e.g., some SPAs, heavily dynamic content)
- Screenshot quality is limited by screencast JPEG quality settings
- Element references from snapshot may not be perfectly accurate for all page layouts

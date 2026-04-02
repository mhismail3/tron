#!/bin/bash
# Sample session-start hook.
#
# Place in .tron/hooks/ or ~/.config/tron/hooks/ to activate.
# Receives HookContext JSON on stdin, returns HookResult JSON on stdout.
#
# This hook logs session start info and returns Continue.

CONTEXT=$(cat)

WORKING_DIR=$(echo "$CONTEXT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('workingDirectory', 'unknown'))" 2>/dev/null || echo "unknown")
TIMESTAMP=$(echo "$CONTEXT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timestamp', 'unknown'))" 2>/dev/null || echo "unknown")

echo "{\"action\":\"continue\",\"message\":\"Session started in $WORKING_DIR at $TIMESTAMP\"}"

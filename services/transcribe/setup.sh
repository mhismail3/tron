#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-}"

if [[ -z "$PYTHON_BIN" ]]; then
    if command -v python3.11 >/dev/null 2>&1; then
        PYTHON_BIN="python3.11"
    else
        PYTHON_BIN="python3"
    fi
fi

cd "$SCRIPT_DIR"
"$PYTHON_BIN" -m venv .venv
source "$SCRIPT_DIR/.venv/bin/activate"
python -m pip install --upgrade pip
pip install -r requirements.txt

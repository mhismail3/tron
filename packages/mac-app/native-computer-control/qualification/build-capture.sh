#!/bin/bash
# Artifact preparation only; never launch, install or transition a running Gateway.
set -euo pipefail
exec /usr/bin/python3 "$(dirname "$0")/build_capture.py" "$@"

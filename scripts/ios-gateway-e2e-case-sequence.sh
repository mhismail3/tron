#!/usr/bin/env bash

# Run focused Gateway boundary cases in order. A failed case is authoritative;
# optional result-bundle extraction is performed by the caller and cannot let a
# later passing case overwrite the failure.
run_e2e_case_sequence() {
  (($# >= 2)) || { echo "run_e2e_case_sequence requires a case callback and at least one case" >&2; return 2; }
  local case_callback="$1" test_filter
  shift
  for test_filter in "$@"; do
    if "$case_callback" "$test_filter"; then
      continue
    else
      return "$?"
    fi
  done
  return 0
}

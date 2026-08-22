#!/usr/bin/env bash
# The repo's test entry point. Everything under tests/ runs from here.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
for t in tests/*_test.sh; do
    bash "$t" || fail=1
done
exit "$fail"

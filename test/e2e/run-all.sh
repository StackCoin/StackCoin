#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Python E2E tests ==="
(cd py && uv run pytest "$@")

echo ""
echo "=== TypeScript E2E tests ==="
(cd ts && pnpm test)

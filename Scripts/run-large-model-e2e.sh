#!/bin/bash
# Manual/local real-engine E2E for the curated heavyweight model tier.
#
# This intentionally reuses Scripts/run-engine-e2e.sh so the proof stays on the
# production path: real LaunchSpecResolver → real PieControlLauncher → real
# `pie serve` → /v1/models + chat completion. The only difference from the
# small default wrapper is the staged GGUF coordinate and a hard preflight that
# prevents a stale /Applications engine from satisfying this proof by accident.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_REPO="Qwen/Qwen3-14B-GGUF"
DEFAULT_FILE="Qwen3-14B-Q4_K_M.gguf"
export PIE_TEST_E2E_REPO="${PIE_TEST_E2E_REPO:-$DEFAULT_REPO}"
export PIE_TEST_E2E_FILE="${PIE_TEST_E2E_FILE:-$DEFAULT_FILE}"

find_worktree_pie() {
  local p
  for p in \
    "$ROOT/Vendor/pie/target/release/pie" \
    "$ROOT/Vendor/pie/target/aarch64-apple-darwin/release/pie"
  do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

PIE_BIN="${PIE_BIN:-}"
if [ -z "$PIE_BIN" ]; then
  PIE_BIN="$(find_worktree_pie || true)"
fi

if [ -z "$PIE_BIN" ] || [ ! -x "$PIE_BIN" ]; then
  echo "large-e2e: worktree pie binary not found." >&2
  echo "large-e2e: build it with: make engine-build" >&2
  echo "large-e2e: expected under Vendor/pie/target/.../release/pie" >&2
  exit 2
fi

case "$PIE_BIN" in
  "$ROOT"/Vendor/pie/target/release/pie|"$ROOT"/Vendor/pie/target/*/release/pie)
    ;;
  *)
    if [ "${PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE:-0}" != "1" ]; then
      echo "large-e2e: refusing PIE_BIN outside this worktree: $PIE_BIN" >&2
      echo "large-e2e: use the worktree pie binary for verification, or set" >&2
      echo "large-e2e: PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 only for wrapper self-tests." >&2
      exit 2
    fi
    ;;
esac
export PIE_BIN

RUNNER="${PIE_LARGE_E2E_RUNNER:-$ROOT/Scripts/run-engine-e2e.sh}"
if [ ! -x "$RUNNER" ]; then
  echo "large-e2e: runner not executable: $RUNNER" >&2
  exit 2
fi

echo "large-e2e: manual/local large-model real-engine E2E"
echo "large-e2e: model = $PIE_TEST_E2E_REPO/$PIE_TEST_E2E_FILE"
echo "large-e2e: pie engine = $PIE_BIN"
echo "large-e2e: this may download ~9 GB and is intentionally not part of PR CI"

exec "$RUNNER"

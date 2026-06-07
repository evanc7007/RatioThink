#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-large-model-e2e.sh"

require_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

test_rejects_external_pie_binary_unless_explicitly_overridden() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  set +e
  local output
  output="$(
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_RUNNER="$tmp/runner" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: expected external PIE_BIN to exit 2, got $status" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "worktree pie binary"
  require_contains "$output" "PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1"
}

test_exports_default_large_model_to_real_engine_wrapper() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  touch "$tmp/pie"
  chmod +x "$tmp/pie"
  cat >"$tmp/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
{
  echo "repo=$PIE_TEST_E2E_REPO"
  echo "file=$PIE_TEST_E2E_FILE"
  echo "pie=$PIE_BIN"
} >"$PIE_LARGE_E2E_CAPTURE"
RUNNER
  chmod +x "$tmp/runner"

  local capture="$tmp/capture"
  local output
  output="$(
    PIE_BIN="$tmp/pie" \
    PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
    PIE_LARGE_E2E_RUNNER="$tmp/runner" \
    PIE_LARGE_E2E_CAPTURE="$capture" \
    "$SCRIPT" 2>&1
  )"

  require_contains "$output" "manual/local large-model real-engine E2E"
  require_contains "$output" "Qwen/Qwen3-14B-GGUF/Qwen3-14B-Q4_K_M.gguf"
  require_contains "$(cat "$capture")" "repo=Qwen/Qwen3-14B-GGUF"
  require_contains "$(cat "$capture")" "file=Qwen3-14B-Q4_K_M.gguf"
  require_contains "$(cat "$capture")" "pie=$tmp/pie"
}

test_preserves_operator_repo_file_override() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  touch "$tmp/pie"
  chmod +x "$tmp/pie"
  cat >"$tmp/runner" <<'RUNNER'
#!/bin/bash
set -euo pipefail
echo "$PIE_TEST_E2E_REPO/$PIE_TEST_E2E_FILE" >"$PIE_LARGE_E2E_CAPTURE"
RUNNER
  chmod +x "$tmp/runner"

  local capture="$tmp/capture"
  PIE_BIN="$tmp/pie" \
  PIE_LARGE_E2E_ALLOW_EXTERNAL_PIE=1 \
  PIE_LARGE_E2E_RUNNER="$tmp/runner" \
  PIE_LARGE_E2E_CAPTURE="$capture" \
  PIE_TEST_E2E_REPO="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF" \
  PIE_TEST_E2E_FILE="Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf" \
    "$SCRIPT" >/dev/null

  require_contains "$(cat "$capture")" \
    "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"
}

test_rejects_external_pie_binary_unless_explicitly_overridden
test_exports_default_large_model_to_real_engine_wrapper
test_preserves_operator_repo_file_override
echo "test-run-large-model-e2e: PASS"

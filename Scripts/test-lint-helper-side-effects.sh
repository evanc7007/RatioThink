#!/bin/bash
# Smoke-tests `lint-helper-side-effects.sh` by feeding it synthetic
# Helper sources that exercise each pattern + each bypass attempt the
# review v4 F7 finding called out. Lint must (a) catch every API in
# the unguarded fixtures and (b) accept every API in the gated
# fixtures and the well-formed allow-list fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/Scripts/lint-helper-side-effects.sh"

TMP=$(mktemp -d -t pie-lint-self-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Helper"

write_fixture() {
  local name="$1"; shift
  cat > "$TMP/Helper/$name"
}

run_lint_in() {
  ( cd "$1" && "$LINT" 2>&1 ) || true
  echo "EXIT=$?"
}

scenario() {
  local label="$1"; shift
  local expect="$1"; shift  # PASS|FAIL
  local body="$1"

  rm -f "$TMP/Helper"/*.swift
  echo "$body" > "$TMP/Helper/Fixture.swift"

  local output rc
  output=$(LINT_HELPER_ROOT="$TMP" "$LINT" 2>&1 || true)
  if echo "$output" | tail -1 | grep -q '^lint(side-effect): ok'; then
    rc=PASS
  else
    rc=FAIL
  fi

  if [ "$rc" != "$expect" ]; then
    echo "FAIL [$label] expected $expect got $rc"
    echo "--- lint output:"
    echo "$output"
    echo "--- fixture:"
    cat "$TMP/Helper/Fixture.swift"
    return 1
  fi
  echo "ok   [$label] $rc"
}

# Each known API in its unguarded form must trip lint.
for api in \
  'SMAppService.loginItem(identifier: "x").register()' \
  'SecItemAdd(query as CFDictionary, nil)' \
  'SecKeychainAddGenericPassword(nil, 0, "", 0, "", 0, "", nil)' \
  'IOPMAssertionCreateWithName("a" as CFString, 0, "b" as CFString, nil)' \
  'NSXPCListener(machServiceName: HelperConfig.xpcServiceName)' \
  'xpc_connection_create_mach_service("x", nil, 0)' \
  'NSStatusBar.system.statusItem(withLength: 0)' \
  'LSRegisterURL(u as CFURL, true)' \
  'AXIsProcessTrusted()' \
  'CFNotificationCenterPostNotification(nil, nil, nil, nil, false)' \
  'DistributedNotificationCenter.default().post(name: .init("x"), object: nil)' \
  'NSPasteboard.general.clearContents()' \
  'posix_spawn(&pid, "/bin/ls", nil, nil, nil, nil)' \
  'CFPreferencesSetValue("k" as CFString, nil, "d" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)' \
; do
  scenario "unguarded: $api" FAIL "func f() { $api }"
done

# Gating via assertSystemSideEffectAllowed(...) within window must pass.
scenario "gated SMAppService passes" PASS '
func f() {
  HelperConfig.assertSystemSideEffectAllowed("login")
  SMAppService.loginItem(identifier: "x").register()
}'

# Allow-list with reason after colon must pass.
scenario "allow with reason passes" PASS '
func f() {
  SMAppService.loginItem(identifier: "x").register() // lint:allow-side-effect: deliberate prod registration
}'

# Allow-list WITHOUT reason must fail.
scenario "allow without reason fails" FAIL '
func f() {
  SMAppService.loginItem(identifier: "x").register() // lint:allow-side-effect
}'

# Comment-only mention of the API must NOT trip lint.
scenario "comment-only NSXPCListener passes" PASS '
/// Future phase-2 wires NSXPCListener(machServiceName:) to bind the
/// helper. Until then this file has no actual XPC code.
func f() {}'

# Bare `assertSystemSideEffectAllowed` (no call parens) within window
# must NOT satisfy the contract — only the callable form counts.
scenario "bare token within window fails" FAIL '
/// Comment mentioning assertSystemSideEffectAllowed for context.
func f() {
  SMAppService.loginItem(identifier: "x").register()
}'

# Documented limitation (review v5 F10): split-line API calls are
# invisible to the line-oriented regex. We assert the failure mode is
# at least loud — the receiver chain split across newlines DOES NOT
# trip lint (PASS), which is wrong but documented. If this assertion
# starts FAILing, the lint script gained multi-line support and the
# docs + this fixture should be updated.
scenario "KNOWN BYPASS: split-line NSStatusBar passes (documented gap)" PASS '
func f() {
  let bar = NSStatusBar
    .system
  let item = bar.statusItem(withLength: 0)
  _ = item
}'

# Same documented gap for an even more aggressive split — the
# receiver token alone never reaches a line with the full call.
scenario "KNOWN BYPASS: receiver-only line passes (documented gap)" PASS '
func f() {
  _ = NSXPCListener
    (
      machServiceName: "x"
    )
}'

echo "lint self-test: all scenarios pass"

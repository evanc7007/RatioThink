#!/bin/bash
# Greps the Helper bundle for known system-singleton side-effect APIs
# and requires each hit to live within a small window of an
# `assertSystemSideEffectAllowed(...)` call. Catches the case where a
# future subsystem (keychain write, IOPMAssertion, XPC bind, etc) is
# added without flowing through the choke point — defeating the
# isolation contract laid out in .
#
# Heuristic, not airtight. Allow-list a deliberate exception by adding
# a line-trailing comment of the form:
#   // lint:allow-side-effect: <one-line reason>
# The reason text after the colon is REQUIRED — a bare
# `// lint:allow-side-effect` does not pass (review v4 F7).
#
# KNOWN LIMITATION (review v5 F10): regex is line-oriented. A call
# whose receiver chain is split across newlines (`NSStatusBar\n
# .system\n.statusItem(...)`) will NOT match. Authors that want the
# lint to enforce gating on a split call must reformat the call to a
# single line OR add a `// lint:allow-side-effect: <reason>` to one
# of the split lines AND ensure an `assertSystemSideEffectAllowed(`
# call lives within ±WINDOW of EVERY line of the split call. The
# self-test fixture `multi-line` documents this failure mode
# explicitly so any reader who imports this script sees the gap.
set -euo pipefail

# ROOT defaults to the repo root containing the Helper/ tree. The
# self-test (Scripts/test-lint-helper-side-effects.sh) overrides this
# via $LINT_HELPER_ROOT to point at a synthetic fixture dir.
ROOT="${LINT_HELPER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Subtrees scanned for ungated system side effects. `Shared/XPC` was
# added in review v1 F2 — the actual `NSXPCListener(machServiceName:)`
# bind lives in `Shared/XPC/HelperXPCListener.swift`, so scanning only
# `Helper/` let a future caller drop the assertion without lint
# noticing.
SCAN_SUBTREES=(Helper Shared/XPC)
WINDOW=8  # lines
# Require the callable form `assertSystemSideEffectAllowed(...)`, not
# the bare token (otherwise the doc-comment that names the symbol
# would satisfy the proximity check). Review v4 F7.
GATE_RE='assertSystemSideEffectAllowed[[:space:]]*\('
ALLOW_RE='lint:allow-side-effect:[[:space:]]*[^[:space:]]'

# (regex, human-name) pairs of APIs that publish/touch system-wide
# state. List grown per review v4 F7 — these are call-site patterns
# (whitespace + linebreak-tolerant where reasonable). Hand-extend when
# a new known-leaky API is added in a Helper subsystem.
PATTERNS=(
  'SMAppService\.'                'SMAppService'
  'SecItem(Add|Update|Delete|CopyMatching)\b' 'SecItem*'
  'SecKeychain[A-Za-z]+\b'        'SecKeychain*'
  'IOPMAssertion[A-Za-z]+\b'      'IOPMAssertion*'
  'NSXPCListener[[:space:]]*\('   'NSXPCListener'
  'xpc_connection_create_mach_service' 'xpc_connection_create_mach_service'
  'NSStatusBar\.system\.statusItem' 'NSStatusBar.statusItem'
  'LSRegisterURL\b'               'LSRegisterURL'
  'AXIsProcessTrusted\b'          'AXIsProcessTrusted'
  'CFNotificationCenter[A-Za-z]+\b' 'CFNotificationCenter*'
  'DistributedNotificationCenter' 'DistributedNotificationCenter'
  'NSPasteboard\.general'         'NSPasteboard.general'
  'posix_spawn\b'                 'posix_spawn'
  'CFPreferencesSetValue\b'       'CFPreferencesSetValue'
)

violations=0

scan_pattern() {
  local pattern="$1"
  local label="$2"
  local scan_paths=()
  for sub in "${SCAN_SUBTREES[@]}"; do
    if [ -d "$ROOT/$sub" ]; then
      scan_paths+=("$ROOT/$sub")
    fi
  done
  [ ${#scan_paths[@]} -eq 0 ] && return 0
  # Scan Swift sources only: these patterns are Swift call-site
  # heuristics, and the comment-skip below only understands Swift
  # comments. Non-Swift files (plists, JSON, Markdown) that merely name
  # an API in text would otherwise false-positive (: the agent
  # plist's XML comment mentions SMAppService).
  local matches
  if command -v rg >/dev/null 2>&1; then
    matches=$(rg --no-heading --line-number -g '*.swift' -e "$pattern" "${scan_paths[@]}" 2>/dev/null || true)
  else
    matches=$(grep -rnE --include='*.swift' "$pattern" "${scan_paths[@]}" 2>/dev/null || true)
  fi
  [ -z "$matches" ] && return 0

  while IFS= read -r hit; do
    local file line snippet
    file=$(echo "$hit" | awk -F: '{print $1}')
    line=$(echo "$hit" | awk -F: '{print $2}')
    snippet=$(echo "$hit" | cut -d: -f3-)

    # Skip pure-comment lines — they describe the API, don't invoke it.
    # Strip leading whitespace; if the result starts with `//` or `///`
    # the match is comment-only (review v4 F7).
    local trimmed
    trimmed=$(echo "$snippet" | sed -E 's/^[[:space:]]*//')
    case "$trimmed" in
      //*|///*|\*\*) continue ;;
    esac

    # Allow-list comment on the SAME line — must include a non-empty
    # reason after the colon. Bare `lint:allow-side-effect` no longer
    # passes (review v4 F7).
    if echo "$snippet" | grep -qE "$ALLOW_RE"; then
      continue
    fi

    # Window check ±WINDOW lines: require the callable form
    # `assertSystemSideEffectAllowed(...)`. A bare doc-comment or
    # variable mention doesn't satisfy the contract.
    local lo=$((line > WINDOW ? line - WINDOW : 1))
    local hi=$((line + WINDOW))
    if sed -n "${lo},${hi}p" "$file" | grep -qE "$GATE_RE"; then
      continue
    fi

    echo "lint(side-effect): $file:$line uses $label without nearby callable assertSystemSideEffectAllowed(...):"
    echo "  $snippet"
    violations=$((violations + 1))
  done <<<"$matches"
}

i=0
while [ $i -lt ${#PATTERNS[@]} ]; do
  scan_pattern "${PATTERNS[$i]}" "${PATTERNS[$((i+1))]}"
  i=$((i + 2))
done

if [ $violations -gt 0 ]; then
  echo "lint(side-effect): $violations violation(s) — gate the call via HelperConfig.assertSystemSideEffectAllowed(_:) or add '// lint:allow-side-effect: <reason>'." >&2
  exit 1
fi

echo "lint(side-effect): ok (no ungated system side effects in ${SCAN_SUBTREES[*]})"

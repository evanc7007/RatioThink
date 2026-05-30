#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

TAG="chat gui e2e"
MODEL="${PIE_TEST_CHAT_MODEL:-Qwen/Qwen3-0.6B}"
HF_HOME_DIR="${HF_HOME:-$HOME/.cache/huggingface}"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p258-$$}"
ENGINE_HOME="$RUN_ROOT/e"
GUI_HOME="$RUN_ROOT/g"
URL_FILE="$RUN_ROOT/engine.url"
HARNESS_LOG="$RUN_ROOT/engine-harness.log"
CONFIG_FILE="/tmp/pie-chat-gui-e2e.env"
ENGINE_PID=""

cleanup() {
  rm -f "$CONFIG_FILE"
  if [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" >/dev/null 2>&1; then
    kill "$ENGINE_PID" >/dev/null 2>&1 || true
    wait "$ENGINE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Preconditions + auto-prep. Human-only gates fail fast with
# exact fix steps; pie + the HF model are built/downloaded automatically
# (disable with PIE_E2E_AUTOPREP=0).
e2e_require_seated_gui "$TAG" || exit 2
e2e_require_tcc "$TAG" || exit 2
e2e_require_chat_apc "$ROOT" "$TAG" || exit 2
PIE_BIN="$(e2e_ensure_pie "$ROOT" "$TAG")" || exit 2
e2e_ensure_hf_model "$MODEL" "$HF_HOME_DIR" "$TAG" || exit 2

mkdir -p "$ENGINE_HOME" "$GUI_HOME"
rm -f "$URL_FILE" "$CONFIG_FILE"

echo "chat gui e2e: generating Xcode project"
Scripts/genproject.sh

echo "chat gui e2e: starting small-model engine harness"
PIE_BIN="$PIE_BIN" \
PIE_TEST_CHAT_MODEL="$MODEL" \
PIE_TEST_ENGINE_HOME="$ENGINE_HOME" \
PIE_TEST_ENGINE_URL_FILE="$URL_FILE" \
xcrun swift run chat-engine-harness >"$HARNESS_LOG" 2>&1 &
ENGINE_PID=$!

for _ in $(seq 1 180); do
  if [ -s "$URL_FILE" ]; then
    break
  fi
  if ! kill -0 "$ENGINE_PID" >/dev/null 2>&1; then
    echo "chat gui e2e: engine harness exited before publishing URL" >&2
    cat "$HARNESS_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ ! -s "$URL_FILE" ]; then
  echo "chat gui e2e: timed out waiting for engine URL" >&2
  cat "$HARNESS_LOG" >&2 || true
  exit 1
fi

BASE_URL="$(cat "$URL_FILE")"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_ENGINE_BASE_URL=$BASE_URL
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_TEST_CHAT_MODEL=$MODEL
EOF

echo "chat gui e2e: engine=$BASE_URL"
echo "chat gui e2e: model=$MODEL"
echo "chat gui e2e: gui PIE_HOME=$GUI_HOME"
echo "chat gui e2e: config=$CONFIG_FILE"
echo "chat gui e2e: retained run root: $RUN_ROOT"
echo "chat gui e2e: running XCUITest"

xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S258_ComposerSendGUITests/test_composer_send_streams_real_assistant_and_persists_after_relaunch \
  ENABLE_CODE_COVERAGE=NO

if ! sqlite3 "$GUI_HOME/chats.sqlite" \
  "select ZCONTENT from ZMESSAGE where ZROLE = 'assistant';" \
  | grep -F "Paris" >/dev/null; then
  echo "chat gui e2e: persisted assistant row missing Paris in $GUI_HOME/chats.sqlite" >&2
  sqlite3 "$GUI_HOME/chats.sqlite" \
    "select ZROLE, ZCONTENT, ZMETA from ZMESSAGE order by ZTS;" >&2 || true
  exit 1
fi

echo "chat gui e2e: persisted assistant row contains Paris"
echo "chat gui e2e: PASS"

#!/bin/bash
set -euo pipefail

# Qdown automated verification.
#
# IMPORTANT: the Qdown binary is always launched with **no command-line
# arguments**. macOS' NSDocumentController treats file-like argv entries as
# documents to open; during unattended runs a bad entry raises a modal alert and
# hangs the process forever. All harness settings therefore travel through
# environment variables (QDOWNTEST_*).
#
# Every app launch is wrapped in `timeout`, and lingering Qdown processes are
# killed before and after each step.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Release/Qdown.app"
QS="$APP/Contents/MacOS/Qdown"
OUT="$ROOT/build/test-output"
TIMEOUT_SECS="${QDOWNTEST_TIMEOUT:-90}"

if [ ! -x "$QS" ]; then
  echo "error: $QS not found; run ./scripts/build.sh first" >&2
  exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "error: GNU timeout is required (brew install coreutils)" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/render.json "$OUT"/render-fallback.json "$OUT"/security.json \
      "$OUT"/render.stdout "$OUT"/render.stderr \
      "$OUT"/render-fallback.stdout "$OUT"/render-fallback.stderr \
      "$OUT"/security.stdout "$OUT"/security.stderr \
      "$OUT"/smoke-two.stdout "$OUT"/smoke-two.stderr \
      "$OUT"/smoke-zoom.stdout "$OUT"/smoke-zoom.stderr \
      "$OUT"/smoke-link.stdout "$OUT"/smoke-link.stderr \
      "$OUT"/01-top.png "$OUT"/02-mermaid.png "$OUT"/03-section.png \
      "$OUT"/04-sidebar.png

kill_qdown() {
  pkill -x Qdown 2>/dev/null || true
  sleep 0.2
  pkill -9 -x Qdown 2>/dev/null || true
}

trap 'kill_qdown' EXIT INT TERM

# run_qdown <name> KEY=VALUE...
# The final command is always just "$QS": no arguments are passed to the app.
run_qdown() {
  local name="$1"
  shift

  echo "==> $name"
  kill_qdown

  local started status
  started="$(date +%s)"
  status=0
  timeout --signal=TERM --kill-after=5 "$TIMEOUT_SECS" env "$@" "$QS" \
    > "$OUT/$name.stdout" 2> "$OUT/$name.stderr" || status=$?
  kill_qdown

  local elapsed=$(( $(date +%s) - started ))
  echo "    exit=$status elapsed=${elapsed}s"

  if [ "$status" -ne 0 ]; then
    echo "error: $name failed (exit $status)" >&2
    tail -20 "$OUT/$name.stderr" >&2 || true
    return "$status"
  fi
}

run_qdown render \
  QDOWNTEST_MODE=render \
  QDOWNTEST_MARKDOWN=test.md \
  QDOWNTEST_JSON=build/test-output/render.json \
  QDOWNTEST_SNAPSHOT=build/test-output/01-top.png \
  QDOWNTEST_SNAPSHOT_DIAGRAM=build/test-output/02-mermaid.png \
  QDOWNTEST_SNAPSHOT_SECTION=build/test-output/03-section.png \
  QDOWNTEST_FIND=Mermaid

run_qdown render-fallback \
  QDOWNTEST_MODE=render \
  QDOWNTEST_MARKDOWN=test.md \
  QDOWNTEST_JSON=build/test-output/render-fallback.json \
  QDOWNTEST_FIND=Mermaid \
  QDOWNTEST_FALLBACK=1

run_qdown security \
  QDOWNTEST_MODE=render \
  QDOWNTEST_MARKDOWN=Tests/fixtures/security.md \
  QDOWNTEST_JSON=build/test-output/security.json \
  QDOWNTEST_FIND=通常

run_qdown smoke-two \
  QDOWNTEST_MODE=smoke \
  QDOWNTEST_FILES=$'test.md\nTests/fixtures/other.md' \
  QDOWNTEST_SIDEBAR_SNAPSHOT=build/test-output/04-sidebar.png

# True cross-process zoom persistence: write the preference outside the app,
# then launch a fresh process that must read it back without seeding.
echo "==> Zoom persistence (fresh process reads UserDefaults)"
/usr/bin/defaults write com.furuhama.qdown QdownPageZoom -float 1.25
run_qdown smoke-zoom \
  QDOWNTEST_MODE=smoke \
  QDOWNTEST_FILES=test.md \
  QDOWNTEST_ZOOM_READ_ONLY=1

run_qdown smoke-link \
  QDOWNTEST_MODE=smoke \
  QDOWNTEST_FILES=test.md \
  QDOWNTEST_LINK=1

echo "==> Checking results"
python3 "$ROOT/Tests/verify_results.py" "$OUT"

echo
echo "==> Architecture"
/usr/bin/lipo -info "$QS"

echo
echo "==> Residual Qdown processes"
if pgrep -x Qdown >/dev/null 2>&1; then
  echo "error: Qdown is still running" >&2
  pgrep -lx Qdown >&2 || true
  exit 1
fi
echo "none"

echo
echo "All checks passed. Artifacts: $OUT"

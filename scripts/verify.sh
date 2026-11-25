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
      "$OUT"/smoke-tabs.stdout "$OUT"/smoke-tabs.stderr "$OUT"/tabs.json \
      "$OUT"/live-reload.json "$OUT"/live-reload.stdout "$OUT"/live-reload.stderr \
      "$OUT"/tabs-screen.json "$OUT"/tabs-screen.stdout "$OUT"/tabs-screen.stderr \
      "$OUT"/smoke-live-tabs.stdout "$OUT"/smoke-live-tabs.stderr "$OUT"/live-tabs.json \
      "$OUT"/01-top.png "$OUT"/02-mermaid.png "$OUT"/03-section.png \
      "$OUT"/05-headerless-window.png "$OUT"/06-headerless-content.png \
      "$OUT"/07-headerless-tabs-window.png "$OUT"/08-headerless-tabs-content.png \
      "$OUT"/09-real-tabs-window.png "$OUT"/10-outline-panel.png \
      "$OUT"/11-single-window.png \
      "$OUT"/session-save.json "$OUT"/session-restore.json \
      "$OUT"/session-arguments.json "$OUT"/production-restore.json \
      "$OUT"/session-save.stdout "$OUT"/session-save.stderr \
      "$OUT"/session-restore.stdout "$OUT"/session-restore.stderr \
      "$OUT"/session-arguments.stdout "$OUT"/session-arguments.stderr \
      "$OUT"/production-restore.stdout "$OUT"/production-restore.stderr
rm -rf "$OUT/AppIcon.iconset"

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
  QDOWNTEST_WINDOW_SNAPSHOT=build/test-output/05-headerless-window.png \
  QDOWNTEST_CONTENT_SNAPSHOT=build/test-output/06-headerless-content.png

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

# Live reload: in-place writes, atomic rename saves, mtime-only changes,
# deletion/recreation, and scroll/zoom preservation. The fixture lives under
# build/test-output so the repository's tracked Markdown files are untouched.
rm -rf "$OUT/live-reload"
run_qdown live-reload \
  QDOWNTEST_MODE=live-reload \
  QDOWNTEST_LIVE_FILE=build/test-output/live-reload/fixture.md \
  QDOWNTEST_JSON=build/test-output/live-reload.json

run_qdown smoke-tabs \
  QDOWNTEST_MODE=tabs \
  QDOWNTEST_FILES=$'test.md\nTests/fixtures/other.md' \
  QDOWNTEST_JSON=build/test-output/tabs.json \
  QDOWNTEST_WINDOW_SNAPSHOT=build/test-output/07-headerless-tabs-window.png \
  QDOWNTEST_CONTENT_SNAPSHOT=build/test-output/08-headerless-tabs-content.png

# The real-screen capture is the authoritative proof of AppKit's native tab
# bar: it is window-server chrome and does not appear in the in-process
# snapshots above. The tabs harness writes the window number and keeps the app
# alive while we record the window with the system screencapture tool;
# Tests/verify_tab_geometry.py then checks the tab bar/full-width geometry and
# that the document starts below it.
echo "==> tabs real-screen geometry (screencapture)"
kill_qdown
rm -f "$OUT"/tabs-screen.json "$OUT"/tabs-screen.stdout "$OUT"/tabs-screen.stderr \
      "$OUT"/09-real-tabs-window.png
timeout --signal=TERM --kill-after=5 "$TIMEOUT_SECS" env \
  QDOWNTEST_MODE=tabs \
  QDOWNTEST_FILES=$'test.md\nTests/fixtures/other.md\nTests/fixtures/security.md' \
  QDOWNTEST_SCREEN_ONLY=1 \
  QDOWNTEST_SCREEN_JSON="$OUT/tabs-screen.json" \
  QDOWNTEST_HOLD_SECONDS=20 \
  "$QS" > "$OUT/tabs-screen.stdout" 2> "$OUT/tabs-screen.stderr" &
screen_pid=$!
for _ in $(seq 1 80); do
  [ -s "$OUT/tabs-screen.json" ] && break
  sleep 0.25
done
if [ ! -s "$OUT/tabs-screen.json" ]; then
  echo "error: tabs screen harness did not write its JSON" >&2
  tail -20 "$OUT/tabs-screen.stderr" >&2 || true
  kill "$screen_pid" 2>/dev/null || true
  wait "$screen_pid" 2>/dev/null || true
  kill_qdown
  exit 1
fi
window_id="$(python3 - "$OUT/tabs-screen.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1]))
print(data.get("windowNumber") or data.get("chrome", {}).get("windowNumber") or "")
PY
)"
if [ -z "$window_id" ]; then
  echo "error: tabs-screen.json has no windowNumber" >&2
  kill "$screen_pid" 2>/dev/null || true
  wait "$screen_pid" 2>/dev/null || true
  kill_qdown
  exit 1
fi
capture_status=0
caffeinate -u -t 1
/usr/sbin/screencapture -x -o -l "$window_id" "$OUT/09-real-tabs-window.png" || capture_status=$?
kill_qdown
wait "$screen_pid" 2>/dev/null || true
if [ "$capture_status" -ne 0 ] || [ ! -s "$OUT/09-real-tabs-window.png" ]; then
  echo "error: screencapture failed for window $window_id (status $capture_status)" >&2
  exit 1
fi
echo "    captured window $window_id -> 09-real-tabs-window.png"

# capture_window <name> <png> <json> [extra env assignments...]
# Starts a single-document window harness, waits for its window number, then
# records that window with screencapture. The app is always started with only
# environment settings (no option-style argv).
capture_window() {
  local name="$1" png="$2" json="$3"
  shift 3

  echo "==> $name (screencapture)"
  kill_qdown
  rm -f "$json" "$OUT/$name.stdout" "$OUT/$name.stderr" "$png"
  timeout --signal=TERM --kill-after=5 "$TIMEOUT_SECS" env \
    QDOWNTEST_MODE=window \
    QDOWNTEST_FILES=test.md \
    QDOWNTEST_SCREEN_JSON="$json" \
    QDOWNTEST_HOLD_SECONDS=20 \
    "$@" "$QS" > "$OUT/$name.stdout" 2> "$OUT/$name.stderr" &
  local pid=$!
  for _ in $(seq 1 80); do
    [ -s "$json" ] && break
    sleep 0.25
  done
  if [ ! -s "$json" ]; then
    echo "error: $name harness did not write its JSON" >&2
    tail -20 "$OUT/$name.stderr" >&2 || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill_qdown
    exit 1
  fi
  local window_id
  window_id="$(python3 - "$json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1]))
print(data.get("windowNumber") or data.get("chrome", {}).get("windowNumber") or "")
PY
  )"
  if [ -z "$window_id" ]; then
    echo "error: $json has no windowNumber" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill_qdown
    exit 1
  fi
  local capture_status=0
  caffeinate -u -t 1
  /usr/sbin/screencapture -x -o -l "$window_id" "$png" || capture_status=$?
  kill_qdown
  wait "$pid" 2>/dev/null || true
  if [ "$capture_status" -ne 0 ] || [ ! -s "$png" ]; then
    echo "error: screencapture failed for $name (window $window_id, status $capture_status)" >&2
    exit 1
  fi
  echo "    captured window $window_id -> $(basename "$png")"
}

# Tab session persistence: one process opens five tabs (one file twice, one
# temporary tab that is closed before quitting), then terminates normally.
# A second process restores the session after one file has been deleted.
echo "==> Tab session persistence"
SESSION_DIR="$OUT/session"
rm -rf "$SESSION_DIR"
mkdir -p "$SESSION_DIR"
cp test.md "$SESSION_DIR/a.md"
cp Tests/fixtures/other.md "$SESSION_DIR/b.md"
cp Tests/fixtures/security.md "$SESSION_DIR/c.md"
cp test.md "$SESSION_DIR/temp.md"
/usr/bin/defaults delete com.furuhama.qdown.sessiontest 2>/dev/null || true

SESSION_FILES="$(printf '%s\n' \
  "$SESSION_DIR/a.md" \
  "$SESSION_DIR/b.md" \
  "$SESSION_DIR/a.md" \
  "$SESSION_DIR/c.md" \
  "$SESSION_DIR/temp.md")"
run_qdown session-save \
  QDOWNTEST_MODE=session-save \
  QDOWNTEST_SESSION_SUITE=com.furuhama.qdown.sessiontest \
  QDOWNTEST_SESSION_ACTIVE=2 \
  QDOWNTEST_FILES="$SESSION_FILES" \
  QDOWNTEST_JSON=build/test-output/session-save.json

rm -f "$SESSION_DIR/c.md"
run_qdown session-restore \
  QDOWNTEST_MODE=session-restore \
  QDOWNTEST_SESSION_SUITE=com.furuhama.qdown.sessiontest \
  QDOWNTEST_JSON=build/test-output/session-restore.json

# The same restore through the real production launch path (no QDOWNTEST_MODE):
# the app delegate reads the saved session after waiting for open events.
echo "==> production launch restore"
kill_qdown
rm -f "$OUT/production-restore.json" "$OUT/production-restore.stdout" "$OUT/production-restore.stderr"
timeout --signal=TERM --kill-after=5 "$TIMEOUT_SECS" env \
  QDOWNTEST_SESSION_SUITE=com.furuhama.qdown.sessiontest \
  QDOWNTEST_SESSION_REPORT="$OUT/production-restore.json" \
  "$QS" > "$OUT/production-restore.stdout" 2> "$OUT/production-restore.stderr" &
production_pid=$!
for _ in $(seq 1 80); do
  [ -s "$OUT/production-restore.json" ] && break
  sleep 0.25
done
kill_qdown
wait "$production_pid" 2>/dev/null || true
if [ ! -s "$OUT/production-restore.json" ]; then
  echo "error: production launch did not restore the saved session" >&2
  tail -20 "$OUT/production-restore.stderr" >&2 || true
  exit 1
fi
restored_tabs=$(python3 - "$OUT/production-restore.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["tabCount"])
PY
)
echo "    restored ${restored_tabs} tab(s)"

run_qdown session-arguments \
  QDOWNTEST_MODE=session-arguments \
  QDOWNTEST_SESSION_SUITE=com.furuhama.qdown.sessiontest \
  QDOWNTEST_FILES="$SESSION_DIR/a.md" \
  QDOWNTEST_JSON=build/test-output/session-arguments.json

# Single document with the floating outline panel forced open (test hook).
capture_window outline-screen "$OUT/10-outline-panel.png" "$OUT/outline-screen.json" \
  QDOWNTEST_OUTLINE_EXPANDED=1
# Single document, headerless: native tab bar hidden, 28pt top strip.
capture_window single-screen "$OUT/11-single-window.png" "$OUT/single-screen.json"

# Real LaunchServices/Mac Finder path: the app is started directly so it can
# read its test environment, then `open -a` delivers ordinary `odoc` open
# events, which NSDocumentController handles itself. No option-style argv is
# ever passed to the app.
echo "==> smoke-live-tabs (LaunchServices open events)"
kill_qdown
rm -f "$OUT/live-tabs.json"
started="$(date +%s)"
status=0
timeout --signal=TERM --kill-after=5 "$TIMEOUT_SECS" bash -c '
  qs="$1"; app="$2"; first="$3"; second="$4"; json="$5"; out="$6"
  env QDOWNTEST_MODE=live-tabs QDOWNTEST_JSON="$json" QDOWNTEST_EXPECT_COUNT=2 \
    "$qs" > "$out.stdout" 2> "$out.stderr" &
  pid=$!
  sleep 3
  open -a "$app" "$first"
  sleep 5
  open -a "$app" "$second"
  wait "$pid"
' _ "$QS" "$APP" "$ROOT/test.md" "$ROOT/Tests/fixtures/other.md" \
    "$OUT/live-tabs.json" "$OUT/smoke-live-tabs" || status=$?
kill_qdown
elapsed=$(( $(date +%s) - started ))
echo "    exit=$status elapsed=${elapsed}s"
if [ "$status" -ne 0 ]; then
  echo "error: smoke-live-tabs failed (exit $status)" >&2
  tail -20 "$OUT/smoke-live-tabs.stderr" >&2 || true
  exit "$status"
fi

echo "==> Checking real-screen geometry"
python3 "$ROOT/Tests/verify_tab_geometry.py" "$OUT/09-real-tabs-window.png" "$OUT/tabs-screen.json"
python3 "$ROOT/Tests/verify_tab_geometry.py" "$OUT/10-outline-panel.png" "$OUT/outline-screen.json"
python3 "$ROOT/Tests/verify_tab_geometry.py" "$OUT/11-single-window.png" "$OUT/single-screen.json"

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

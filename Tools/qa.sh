#!/bin/zsh
# Off-screen QA harness: runs a test copy of Folio (no Dock icon, window off-screen, throwaway HOME,
# never takes focus) that you drive with debug commands and snapshot to PNG. See CLAUDE.md.
#
#   Tools/qa.sh start            build, create a demo library, launch
#   Tools/qa.sh send "<command>" e.g. "sidebar:library", "read:Strip", "cmd:viewport:0.9"
#   Tools/qa.sh snap out.png     capture the window (Folio's own window only; no screen permission needed)
#   Tools/qa.sh log              show the debug log (reader state, load-in stability, ...)
#   Tools/qa.sh stop
set -euo pipefail
ROOT="${0:A:h:h}"
QA="${TMPDIR:-/tmp}/folio-qa"
TOKEN=qa
HOME_DIR="$QA/home"
cmd="${1:-}"

case "$cmd" in
  start)
    mkdir -p "$QA/bin" "$HOME_DIR/tmp" "$HOME_DIR/Library/Application Support/Folio/Local"
    ( cd "$ROOT" && swift build -c release --product FolioApp 2>&1 | tail -1 )
    swiftc -O "$ROOT/Tools/gen-test-series.swift" -o "$QA/bin/gen" 2>/dev/null
    swiftc -O "$ROOT/Tools/debug-send.swift" -o "$QA/bin/send" 2>/dev/null
    L="$HOME_DIR/Library/Application Support/Folio/Local"
    i=0; for n in "Strip Test" "Midnight Courier" "Iron Harbor"; do [ -d "$L/$n" ] || "$QA/bin/gen" "$L" "$n" $i; i=$((i+4)); done
    : > "$QA/log"
    HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" TMPDIR="$HOME_DIR/tmp/" FOLIO_DEBUG=$TOKEN FOLIO_DEBUG_LOG="$QA/log" \
      "$ROOT/.build/release/FolioApp" >/dev/null 2>"$QA/err" &
    echo $! > "$QA/pid"; sleep 3
    "$QA/bin/send" $TOKEN "size:1440x900"; echo "running (pid $(cat "$QA/pid")); data in $HOME_DIR" ;;
  send) "$QA/bin/send" $TOKEN "$2"; sleep "${3:-1}" ;;
  snap) "$QA/bin/send" $TOKEN "snap:$2"; sleep 1; echo "$2" ;;
  log)  cat "$QA/log" ;;
  stop) "$QA/bin/send" $TOKEN quit 2>/dev/null || true; sleep 1; kill "$(cat "$QA/pid" 2>/dev/null)" 2>/dev/null || true; echo stopped ;;
  *) sed -n 2,11p "$0" ;;
esac

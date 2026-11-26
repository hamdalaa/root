#!/bin/zsh
# UI smoke test: drives every screen and toolbar toggle of the running app through Accessibility,
# then checks the app is still alive and no new crash report appeared. Screenshots go to /tmp/pb-smoke.
# Usage: ./scripts/ui-smoke.sh [path/to/Root.app]   (default: dist/Root.app)
set -euo pipefail
cd "${0:A:h}/.."
APP=${1:-dist/Root.app}
OUT=/tmp/pb-smoke
mkdir -p "$OUT"
REPORTS=~/Library/Logs/DiagnosticReports
before=$(ls -t "$REPORTS" 2>/dev/null | grep -c '^Root-' || true)

pkill -x Root 2>/dev/null || true
sleep 1
open -g "$APP"
sleep 5

swiftc -O scripts/axdrive.swift -o "$OUT/axdrive" 2>/dev/null
# The setup guide may open by itself on first launch; close it so the sidebar can be driven.
"$OUT/axdrive" 1 "Done" >/dev/null || true
SECTIONS=("All Downloads" "Downloading" "Queued" "Completed" "Failed" "Search" "Subscriptions" "History" "Statistics" "Speed Test" "Memory" "Storage" "Cleanup" "Uninstaller" "Login Items" "Force Quit")
TOGGLES=("Hide sidebar" "Show sidebar" "Show as Grid" "Show as List" "Inspector" "Inspector")
drive=$("$OUT/axdrive" 3 "${SECTIONS[@]}" "${TOGGLES[@]}")
print -r -- "$drive"
# Nothing pressed = the window isn't reachable (e.g. on a Space hidden behind a full-screen app): not a pass.
if [[ "$drive" == *"pressed 0"* ]]; then echo "FAIL: no button could be pressed; is Root's window on the current Space?"; exit 1; fi

window_id() {
  swift -e 'import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String:Any]]; let main = l.filter { ($0["kCGWindowOwnerName"] as? String) == "Root" && ($0["kCGWindowLayer"] as? Int) == 0 && (($0["kCGWindowIsOnscreen"] as? Bool) ?? false) }.max { (($0["kCGWindowBounds"] as! [String:Any])["Width"] as! Double) < (($1["kCGWindowBounds"] as! [String:Any])["Width"] as! Double) }; if let main { print(main["kCGWindowNumber"]!) }'
}
shots=0
for section in "${SECTIONS[@]}"; do
  "$OUT/axdrive" 1 "$section" >/dev/null
  sleep 0.8
  wid=$(window_id)
  [[ -n "$wid" ]] && screencapture -x -o -l "$wid" "$OUT/${section// /-}.png" && (( shots += 1 ))
done
if (( shots < ${#SECTIONS[@]} )); then echo "FAIL: only $shots of ${#SECTIONS[@]} screens captured (main window not on screen)"; exit 1; fi

sleep 1
if ! pgrep -x Root >/dev/null; then echo "FAIL: Root is not running"; exit 1; fi
after=$(ls -t "$REPORTS" 2>/dev/null | grep -c '^Root-' || true)
if (( after > before )); then echo "FAIL: new crash report in $REPORTS"; exit 1; fi
cpu=$(ps -o %cpu= -p "$(pgrep -x Root)" | tr -d ' ')
echo "PASS: all screens and toggles driven, no crash, idle CPU ${cpu}%. Screenshots: $OUT"

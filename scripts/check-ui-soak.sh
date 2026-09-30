#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
soak_seconds="${1:-1800}"
extra_flags=("${@:3}")
run_stamp="$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)"
test_bundle_id="io.javis.live-ko-caption.ui-soak-$run_stamp"
report_path="${2:-$project_root/docs/qa/raw/ui-soak-$run_stamp.jsonl}"
report_path="${report_path:A}"
mkdir -p "${report_path:h}"
if [[ -e "$report_path" ]]; then
    print -u2 -r -- "Refusing to reuse an existing UI soak report: $report_path"
    exit 1
fi
python3 - "$soak_seconds" <<'PYVALIDATE'
import math, sys
seconds = float(sys.argv[1])
if not math.isfinite(seconds) or not 1 <= seconds <= 7200:
    raise SystemExit('UI soak duration must be between 1 and 7200 seconds')
PYVALIDATE
swift build --build-system native -c release --product LiveKoCaption
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app_path="$project_root/dist/Live Korean Captions UI Soak-$run_stamp.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# A separate bundle identifier also isolates test display preferences and keeps
# the user's running app and transcript untouched.
cp "$binary_dir/LiveKoCaption" "$app_path/Contents/MacOS/LiveKoCaption.next"
mv -f "$app_path/Contents/MacOS/LiveKoCaption.next" "$app_path/Contents/MacOS/LiveKoCaption"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $test_bundle_id" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Live Korean Captions UI Soak' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Live Korean Captions UI Soak' "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
open -n "$app_path" --args --ui-soak-seconds "$soak_seconds" --ui-soak-output "$report_path" --ui-soak-exit "${extra_flags[@]}"
python3 - "$report_path" "$soak_seconds" "$app_path" <<'PY'
import json, pathlib, subprocess, sys, time
report = pathlib.Path(sys.argv[1])
seconds = float(sys.argv[2])
app_path = pathlib.Path(sys.argv[3])
reopened = False
process_report = report.with_suffix('.process.jsonl')
started = time.monotonic()
pid = None
saw_document = False
last_sample = 0
last_print = 0
with process_report.open('w') as samples:
    while time.monotonic() - started < seconds + 60:
        rows = []
        if report.exists():
            for line in report.read_text().splitlines():
                try: rows.append(json.loads(line))
                except json.JSONDecodeError: pass
        if rows:
            pid = rows[0].get('pid', pid)
            heartbeats = [row for row in rows if row.get('event') == 'heartbeat']
            saw_document |= any(row.get('nativeDocumentCharacters', 0) > 0 for row in heartbeats)
            if saw_document and not last_print:
                print(json.dumps({'event': 'visible-window-running', 'pid': pid, 'report': str(report), 'requestedSeconds': seconds}), flush=True)
                last_print = time.monotonic()
            if time.monotonic() - last_print >= 60 and heartbeats:
                print(json.dumps(heartbeats[-1], sort_keys=True), flush=True)
                last_print = time.monotonic()
            complete = next((row for row in rows if row.get('event') == 'complete'), None)
            if complete:
                print(json.dumps(complete, sort_keys=True), flush=True)
                sys.exit(0 if complete.get('passed') and saw_document and complete.get('elapsedSeconds', 0) >= seconds else 1)
        if time.monotonic() - started > 2 and not saw_document and not reopened:
            # Reopen only this dedicated test app after scene setup. Activating
            # before SwiftUI has a window can otherwise leave its scene hidden.
            subprocess.run(['open', '-a', str(app_path)], check=True)
            reopened = True
        if time.monotonic() - started > 20 and not saw_document:
            raise SystemExit(f'UI soak did not show a caption document: {report}')
        if pid and time.monotonic() - last_sample >= 5:
            result = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu=,rss=,etime='], capture_output=True, text=True)
            parts = result.stdout.split()
            if len(parts) >= 3:
                samples.write(json.dumps({'elapsedSeconds': time.monotonic() - started, 'pid': pid,
                                          'cpuPercent': float(parts[0]), 'rssKiB': int(parts[1]), 'processElapsed': parts[2]}) + '\n')
                samples.flush()
            last_sample = time.monotonic()
        time.sleep(1)
raise SystemExit(f'UI soak did not complete: {report}')
PY

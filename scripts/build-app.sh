#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
swift build --build-system native -c release --product LiveKoCaption
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app_path="$project_root/dist/Live Korean Captions.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/LiveKoCaption" "$app_path/Contents/MacOS/LiveKoCaption.next"
mv -f "$app_path/Contents/MacOS/LiveKoCaption.next" "$app_path/Contents/MacOS/LiveKoCaption"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
print -r -- "$app_path"

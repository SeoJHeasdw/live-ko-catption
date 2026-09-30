#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
./scripts/build-local-runtime.sh
swift build --build-system native -c release --product LiveKoCaption
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app_path="$project_root/dist/Live Korean Captions.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/ThirdParty" "$app_path/Contents/Frameworks"
cp "$binary_dir/LiveKoCaption" "$app_path/Contents/MacOS/LiveKoCaption.next"
mv -f "$app_path/Contents/MacOS/LiveKoCaption.next" "$app_path/Contents/MacOS/LiveKoCaption"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_root/Resources/local-model-manifest.json" "$app_path/Contents/Resources/"
cp "$project_root/Resources/ThirdParty/"*.txt "$app_path/Contents/Resources/ThirdParty/"
cp "$project_root/Runtime/llama-cpp-LICENSE.txt" "$app_path/Contents/Resources/ThirdParty/llama-cpp-LICENSE.txt"
cp "$project_root/.build/local-runtime/libcaption_local_translation.dylib" "$app_path/Contents/Frameworks/libcaption_local_translation.next.dylib"
mv -f "$app_path/Contents/Frameworks/libcaption_local_translation.next.dylib" "$app_path/Contents/Frameworks/libcaption_local_translation.dylib"
codesign --force --sign - "$app_path/Contents/Frameworks/libcaption_local_translation.dylib"
codesign --force --sign - "$app_path"
print -r -- "$app_path"

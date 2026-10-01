#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="$project_root/.build/system-audio-checks"
mkdir -p "$checks_path"
fixture="$checks_path/system-audio-fixture.aiff"
# The first sentence is lost while the tap attaches to the already playing process.
print -r -- "Testing, testing, one, two, three. Please check the date carefully because the meeting is on Tuesday, not Thursday. We should not cancel the appointment unless someone confirms the change." > "$checks_path/system-audio-fixture.txt"
/usr/bin/say -v Samantha -r 175 -f "$checks_path/system-audio-fixture.txt" -o "$fixture"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -emit-library -emit-module -module-name CaptionCore \
    Sources/CaptionCore/*.swift -emit-module-path "$checks_path/CaptionCore.swiftmodule" \
    -o "$checks_path/libCaptionCore.dylib"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_path" -L "$checks_path" -lCaptionCore -Xlinker -rpath -Xlinker "$checks_path" \
    Sources/LiveKoCaption/AudioCapture.swift Sources/LiveKoCaption/AudioDeviceCapture.swift \
    Tests/SystemAudioChecks/SystemAudioChecks.swift \
    -o "$checks_path/SystemAudioChecks"
exec "$checks_path/SystemAudioChecks" "$fixture"

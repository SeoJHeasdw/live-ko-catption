#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="$project_root/.build/prompt-safety-checks"
mkdir -p "$checks_path"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 \
    -emit-library -emit-module -module-name CaptionCore Sources/CaptionCore/*.swift \
    -emit-module-path "$checks_path/CaptionCore.swiftmodule" -o "$checks_path/libCaptionCore.dylib"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_path" -L "$checks_path" -lCaptionCore \
    -Xlinker -rpath -Xlinker "$checks_path" \
    Tests/PromptSafetyChecks/PromptSafetyChecks.swift -o "$checks_path/PromptSafetyChecks"
"$checks_path/PromptSafetyChecks"

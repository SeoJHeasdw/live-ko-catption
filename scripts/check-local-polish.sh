#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
# Use a different override directory for a short comparison while a long soak
# still has its original CaptionCore dylib mapped into a running process.
checks_path="${LOCAL_POLISH_CHECKS_BUILD_PATH:-$project_root/.build/local-polish-checks}"
mkdir -p "$checks_path"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -emit-library -emit-module -module-name CaptionCore \
    -emit-module-path "$checks_path/CaptionCore.swiftmodule" \
    Sources/CaptionCore/*.swift -o "$checks_path/libCaptionCore.dylib"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_path" -L "$checks_path" -lCaptionCore \
    -Xlinker -rpath -Xlinker "$checks_path" \
    Sources/LiveKoCaption/OperationDeadline.swift \
    Sources/LiveKoCaption/TranslationSessionLease.swift \
    Sources/LiveKoCaption/LocalTranslationEngine.swift \
    Tests/LocalPolishChecks/LocalPolishChecks.swift \
    -o "$checks_path/LocalPolishChecks"
exec "$checks_path/LocalPolishChecks" "$@"

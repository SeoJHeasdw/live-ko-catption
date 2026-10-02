#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="${DICTIONARY_REALTIME_CHECKS_BUILD_PATH:-$project_root/.build/dictionary-realtime-checks}"
mode="build-and-run"
if [[ "${1:-}" == "--build-only" || "${1:-}" == "--run-only" ]]; then
    mode="${1#--}"
    shift
fi
mkdir -p "$checks_path"
if [[ "$mode" != "run-only" ]]; then
    xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
        -emit-library -emit-module -module-name CaptionCore \
        Sources/CaptionCore/*.swift -emit-module-path "$checks_path/CaptionCore.swiftmodule" \
        -o "$checks_path/libCaptionCore.dylib"
    xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
        -I "$checks_path" -L "$checks_path" -lCaptionCore \
        -Xlinker -rpath -Xlinker "$checks_path" \
        Sources/LiveKoCaption/AudioCapture.swift Sources/LiveKoCaption/AudioDeviceCapture.swift \
        Sources/LiveKoCaption/OperationDeadline.swift Sources/LiveKoCaption/TranslationSessionLease.swift \
        Sources/LiveKoCaption/LocalModelStore.swift Sources/LiveKoCaption/LocalTranslationEngine.swift \
        Sources/LiveKoCaption/CaptionModel.swift \
        Tests/DictionaryRealtimeChecks/DictionaryRealtimeChecks.swift \
        -o "$checks_path/DictionaryRealtimeChecks"
fi
if [[ "$mode" == "build-only" ]]; then
    print -r -- "Dictionary realtime runner built; no model or translation engine opened."
    exit 0
fi
exec "$checks_path/DictionaryRealtimeChecks" "$@"

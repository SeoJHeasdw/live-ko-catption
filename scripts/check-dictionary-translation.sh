#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="${DICTIONARY_TRANSLATION_CHECKS_BUILD_PATH:-$project_root/.build/dictionary-translation-checks}"
mkdir -p "$checks_path"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -emit-library -emit-module -module-name CaptionCore \
    -emit-module-path "$checks_path/CaptionCore.swiftmodule" \
    Sources/CaptionCore/*.swift -o "$checks_path/libCaptionCore.dylib"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_path" -L "$checks_path" -lCaptionCore \
    -Xlinker -rpath -Xlinker "$checks_path" \
    Sources/LiveKoCaption/LocalTranslationEngine.swift \
    Tests/DictionaryTranslationChecks/DictionaryTranslationChecks.swift \
    -o "$checks_path/DictionaryTranslationChecks"
exec "$checks_path/DictionaryTranslationChecks" "$@"

#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="$project_root/.build/local-model-store-checks"
mkdir -p "$checks_path"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -target arm64-apple-macos26.4 -parse-as-library \
    Sources/LiveKoCaption/LocalModelStore.swift \
    Tests/LocalModelStoreChecks/LocalModelStoreChecks.swift \
    -o "$checks_path/LocalModelStoreChecks"
exec "$checks_path/LocalModelStoreChecks"

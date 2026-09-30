#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
mkdir -p .build/checks
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    Sources/LiveKoCaption/TranslationSessionLease.swift \
    Tests/TranslationLeaseChecks/TranslationLeaseChecks.swift \
    -o .build/checks/TranslationLeaseChecks
.build/checks/TranslationLeaseChecks

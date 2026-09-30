#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
mkdir -p .build/checks
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    Sources/LiveKoCaption/AudioCapture.swift \
    Sources/CaptionCore/CaptionTimeline.swift \
    Tests/AudioCallbackChecks/AudioCallbackChecks.swift \
    -o .build/checks/AudioCallbackChecks
.build/checks/AudioCallbackChecks "$@"

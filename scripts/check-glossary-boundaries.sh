#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="${GLOSSARY_BOUNDARY_CHECKS_BUILD_PATH:-$project_root/.build/glossary-boundary-checks}"
mkdir -p "$checks_path"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.4 -parse-as-library \
    Sources/CaptionCore/*.swift \
    Tests/GlossaryBoundaryChecks/GlossaryBoundaryChecks.swift \
    -o "$checks_path/GlossaryBoundaryChecks"
exec "$checks_path/GlossaryBoundaryChecks"

#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
checks_path="$project_root/.build/continuous-checks"
mkdir -p "$checks_path" "$project_root/docs/qa/raw"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -emit-library -emit-module -module-name CaptionCore \
    -emit-module-path "$checks_path/CaptionCore.swiftmodule" \
    Sources/CaptionCore/*.swift -o "$checks_path/libCaptionCore.dylib"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_path" -L "$checks_path" -lCaptionCore \
    -Xlinker -rpath -Xlinker "$checks_path" \
    Sources/LiveKoCaption/AudioCapture.swift \
    Sources/LiveKoCaption/AudioDeviceCapture.swift \
    Sources/LiveKoCaption/OperationDeadline.swift \
    Sources/LiveKoCaption/TranslationSessionLease.swift \
    Sources/LiveKoCaption/CaptionModel.swift \
    Tests/ContinuousPipelineChecks/ContinuousPipelineChecks.swift \
    -o "$checks_path/ContinuousPipelineChecks"
if [[ $# -eq 0 ]]; then
    fixture="$checks_path/continuous-english.aiff"
    if [[ ! -f "$fixture" ]]; then
        say -v Samantha -r 168 -o "$fixture" --input-file "$project_root/Tests/ContinuousPipelineChecks/fixture.txt"
    fi
    report_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    report_path="$project_root/docs/qa/raw/continuous-pipeline-$report_stamp.json"
    print "Continuous pipeline report: $report_path"
    "$checks_path/ContinuousPipelineChecks" --fixture "$fixture" --duration-seconds 1800 --restart-seconds 30 \
        --output "$report_path"
else
    "$checks_path/ContinuousPipelineChecks" "$@"
fi

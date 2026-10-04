#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h:h:h:h}"
probe_root="${0:A:h}"
cd "$project_root"
mkdir -p .build
checks_root="$(mktemp -d "$project_root/.build/adversarial-20261004.XXXXXX")"
print -r -- "Reproduction outputs: $checks_root"
# These probes use synthetic text and PCM; no microphone, downloads or real GGUF.
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 \
    -emit-library -emit-module -module-name CaptionCore Sources/CaptionCore/*.swift \
    -emit-module-path "$checks_root/CaptionCore.swiftmodule" -o "$checks_root/libCaptionCore.dylib"
for name in IdleAudit OrderAudit; do
    xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
        Sources/LiveKoCaption/AudioCapture.swift Sources/LiveKoCaption/AudioDeviceCapture.swift \
        Sources/CaptionCore/CaptionPreferences.swift Sources/CaptionCore/CaptionTimeline.swift \
        "$probe_root/$name.swift" -o "$checks_root/$name"
    "$checks_root/$name" | tee "$checks_root/$name.log"
done
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    Sources/LiveKoCaption/LocalModelStore.swift "$probe_root/ModelCacheAudit.swift" \
    -o "$checks_root/ModelCacheAudit"
"$checks_root/ModelCacheAudit" | tee "$checks_root/ModelCacheAudit.log"
for name in PromptAudit UnicodeAudit PropertyAudit; do
    xcrun swiftc -swift-version 6 -O -target arm64-apple-macos26.4 -parse-as-library \
        Sources/CaptionCore/*.swift "$probe_root/$name.swift" -o "$checks_root/$name"
    "$checks_root/$name" | tee "$checks_root/$name.log"
done
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_root" -L "$checks_root" -lCaptionCore \
    -Xlinker -rpath -Xlinker "$checks_root" \
    Sources/LiveKoCaption/AudioCapture.swift Sources/LiveKoCaption/AudioDeviceCapture.swift \
    Sources/LiveKoCaption/OperationDeadline.swift Sources/LiveKoCaption/TranslationSessionLease.swift \
    Sources/LiveKoCaption/LocalModelStore.swift Sources/LiveKoCaption/LocalTranslationEngine.swift \
    Sources/LiveKoCaption/CaptionModel.swift "$probe_root/DirectionAudit.swift" \
    -o "$checks_root/DirectionAudit"
"$checks_root/DirectionAudit" | tee "$checks_root/DirectionAudit.log"
mkdir -p "$checks_root/core-boundary"
cp "$probe_root/CoreBoundaryAudit.swift" "$checks_root/core-boundary/main.swift"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 \
    Sources/CaptionCore/*.swift "$checks_root/core-boundary/main.swift" \
    -o "$checks_root/CoreBoundaryAudit"
"$checks_root/CoreBoundaryAudit" | tee "$checks_root/CoreBoundaryAudit.log"
# The deliberate export trap stays in a child process and is recorded, not
# confused with a crash in the user's app or with a successful check.
python3 - "$checks_root" <<'PY'
import json, pathlib, subprocess, sys
folder = pathlib.Path(sys.argv[1])
result = subprocess.run([str(folder / 'CoreBoundaryAudit'), '--crash-export'], capture_output=True, text=True)
(folder / 'CoreBoundaryCrash.log').write_text(result.stdout + result.stderr)
print(json.dumps({'probe': 'malformed timestamp export', 'child_returncode': result.returncode}))
PY
print -r -- "These outputs reproduce defects; exit 0 means the probes ran, not that the app passed."

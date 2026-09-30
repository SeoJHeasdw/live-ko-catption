#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
run_stamp="$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)-$(uuidgen | cut -c 1-8)"
checks_path="$project_root/.build/bidirectional-polish-$run_stamp"
audio_path="$checks_path/audio"
report_path="${1:-$project_root/docs/qa/raw/bidirectional-polish-pipeline-$run_stamp.json}"
report_path="${report_path:A}"
if [[ -n "${CAPTION_PIPELINE_MODEL_PATH:-}" ]]; then
    caption_model_path="$CAPTION_PIPELINE_MODEL_PATH"
elif [[ -f "$project_root/.build/local-model/Hy-MT2-1.8B-Q6_K.gguf" ]]; then
    caption_model_path="$project_root/.build/local-model/Hy-MT2-1.8B-Q6_K.gguf"
else
    caption_model_path="$HOME/Library/Application Support/Live Korean Captions/Models/Hy-MT2-1.8B-Q6_K.gguf"
fi
caption_runtime_path="${CAPTION_PIPELINE_RUNTIME_PATH:-$project_root/.build/local-runtime/libcaption_local_translation.dylib}"
mkdir -p "$checks_path" "$audio_path" "${report_path:h}"
if [[ -e "$report_path" ]]; then
    print -u2 -r -- "Refusing to overwrite an existing pipeline report: $report_path"
    exit 1
fi
if [[ ! -f "$caption_model_path" || ! -f "$caption_runtime_path" ]]; then
    print -u2 -r -- "Prepare the verified local GGUF and runtime first; this check does not build or download either."
    exit 1
fi
python3 - "$project_root/Tests/BidirectionalPolishPipelineChecks/fixtures.json" "$audio_path" <<'PY'
import json,pathlib,re,subprocess,sys
fixtures=json.loads(pathlib.Path(sys.argv[1]).read_text())
directory=pathlib.Path(sys.argv[2])
available={row.split()[0] for row in subprocess.check_output(['/usr/bin/say','-v','?'],text=True).splitlines() if row.split()}
for fixture in fixtures:
    if fixture['voice'] not in available:raise SystemExit(f"Missing installed say voice: {fixture['voice']}; no voice download requested.")
    if not re.fullmatch(r'[a-z0-9-]+',fixture['id']):raise SystemExit('Invalid fixture ID')
    text_path=directory/(fixture['id']+'.txt')
    text_path.write_text(fixture['text'])
    subprocess.run(['/usr/bin/say','-v',fixture['voice'],'-r','155','-f',str(text_path),'-o',str(directory/(fixture['id']+'.aiff'))],check=True)
PY
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -emit-library -emit-module -module-name CaptionCore \
    Sources/CaptionCore/*.swift -emit-module-path "$checks_path/CaptionCore.swiftmodule" \
    -o "$checks_path/libCaptionCore.dylib"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library \
    -I "$checks_path" -L "$checks_path" -lCaptionCore -Xlinker -rpath -Xlinker "$checks_path" \
    Sources/LiveKoCaption/AudioCapture.swift Sources/LiveKoCaption/AudioDeviceCapture.swift \
    Sources/LiveKoCaption/OperationDeadline.swift Sources/LiveKoCaption/TranslationSessionLease.swift \
    Sources/LiveKoCaption/LocalModelStore.swift Sources/LiveKoCaption/LocalTranslationEngine.swift \
    Sources/LiveKoCaption/CaptionModel.swift \
    Tests/BidirectionalPolishPipelineChecks/BidirectionalPolishPipelineChecks.swift \
    -o "$checks_path/BidirectionalPolishPipelineChecks"
"$checks_path/BidirectionalPolishPipelineChecks" \
    "$project_root/Tests/BidirectionalPolishPipelineChecks/fixtures.json" "$audio_path" \
    "$caption_model_path" "$caption_runtime_path" "$report_path"

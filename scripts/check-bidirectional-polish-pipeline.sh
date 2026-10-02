#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
run_stamp="$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)-$(uuidgen | cut -c 1-8)"
checks_path="$project_root/.build/bidirectional-polish-$run_stamp"
audio_path="$checks_path/audio"
comparison_mode=false
fixture_source=""
report_argument=""
while (( $# > 0 )); do
    case "$1" in
        --dictionary-comparison) comparison_mode=true; shift ;;
        --fixtures)
            if (( $# < 2 )); then print -u2 -r -- "--fixtures requires a JSON path"; exit 1; fi
            fixture_source="$2"; shift 2 ;;
        --help)
            print -r -- "Usage: $0 [REPORT_JSON] [--dictionary-comparison] [--fixtures FIXTURES_JSON]"
            print -r -- "Comparison reuses two public synthesized English/Korean files in none→all, then all→none order. No model or language download is performed."
            exit 0 ;;
        --*) print -u2 -r -- "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -n "$report_argument" ]]; then print -u2 -r -- "Only one report path may be supplied"; exit 1; fi
            report_argument="$1"; shift ;;
    esac
done
report_path="${report_argument:-$project_root/docs/qa/raw/bidirectional-polish-pipeline-$run_stamp.json}"
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
if [[ "$comparison_mode" == true && -z "$fixture_source" ]]; then
    fixture_source="$checks_path/dictionary-comparison-fixtures.json"
    python3 - "$fixture_source" <<'PY'
import json,pathlib,sys
fixtures = [
    {
        "id": "english-dictionary-comparison", "direction": "englishToKorean", "domain": "general", "voice": "Samantha",
        "text": "IBM watsonx.ai uses a large language model to review credit risk. Keep the bank's anti-money laundering checks and customer data controls in place. I cannot recall the last planning meeting.",
        "meaning": "IBM product and AI model names; review credit risk; retain AML checks and customer data controls; ordinary recall means remembering a meeting."
    },
    {
        "id": "korean-dictionary-comparison", "direction": "koreanToEnglish", "domain": "general", "voice": "Yuna",
        "text": "IBM watsonx.ai에서 대규모 언어 모델로 신용 리스크를 검토합니다. 은행의 자금 세탁 방지 검사와 고객 데이터 통제는 유지하세요. 지난 기획 회의 내용은 기억나지 않습니다.",
        "meaning": "IBM product and AI model names; review credit risk; retain AML checks and customer data controls; the last planning meeting is not remembered."
    }
]
pathlib.Path(sys.argv[1]).write_text(json.dumps(fixtures, ensure_ascii=False, indent=2))
PY
elif [[ -z "$fixture_source" ]]; then
    fixture_source="$project_root/Tests/BidirectionalPolishPipelineChecks/fixtures.json"
fi
fixture_source="${fixture_source:A}"
python3 - "$fixture_source" "$audio_path" <<'PY'
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
runner_arguments=("$fixture_source" "$audio_path" "$caption_model_path" "$caption_runtime_path" "$report_path")
if [[ "$comparison_mode" == true ]]; then runner_arguments+=(--dictionary-comparison); fi
"$checks_path/BidirectionalPolishPipelineChecks" "${runner_arguments[@]}"

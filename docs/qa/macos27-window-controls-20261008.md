# macOS 27 검증과 창 전환·정지 버튼 개선

2026년 10월 8일 0.5.2 build 22 작업의 기록입니다. 실행 환경은 Apple M4 Max, macOS 27.0.1 build 26A434, Swift 6.4이며 최소 지원 대상은 macOS 26.4입니다. 0.5.1까지의 검증은 macOS 26.7.1에서 했으므로, 이번이 macOS 27에서 처음 돌린 결과입니다.

## 고친 것

| 증상 | 원인 | 수정 |
|---|---|---|
| 큰 창에서 일시정지 뒤 재개하면 작은 창으로만 이동 | 듣기가 시작될 때마다 `showCompact()`를 호출 | 빈 대화를 처음 시작할 때만 작은 창으로 이동. 재개와 방향 전환은 보고 있는 창을 유지 |
| 큰 창에서 방향을 바꿀 때마다 작은 창으로 이동 | 방향 전환의 재시작도 같은 경로를 통과 | 위와 같음 |
| 큰 창에는 정지가 없고, 작은 창의 ■는 이름이 "일시정지하고 상세 보기"여서 일시정지와 구분되지 않음 | 정지와 일시정지가 같은 동작이었음 | 두 창에 ⏸ 일시정지·재개와 ■ 정지를 같은 짝으로 둠. 정지(⌘.)는 입력을 멈춘 뒤 저장 후 새 대화 / 저장하지 않고 새 대화 / 일시정지 상태로 두기를 물음. 정지 자체는 기록을 지우지 않음 |
| 다듬기를 쓰지 않아도 앱을 켤 때마다 1.47 GB 모델 전체를 해시. 다듬기를 켜면 두 번 | 0.5.1의 "매 refresh 전체 해시"가 시작 경로에서 무조건 호출됨 | 시작은 다듬기가 켜져 있을 때만 확인·로드. 설정 화면은 처음 볼 때 한 번 확인. 로드 직전의 전체 검증은 그대로 |
| macOS 27에서 `check-audio-callbacks.sh`가 4번째 검사에서 SIGTRAP | 검사 fixture가 Float32를 대상 형식으로 써서 `AnalyzerInput`이 트랩. `input.buffer`는 접근할 때마다 새 버퍼라 임시 버퍼의 포인터를 읽던 코드도 깨짐 | fixture를 앱이 쓰는 16 kHz mono Int16으로 바꾸고 `input.buffer`를 변수에 잡은 뒤 읽음. 앱 코드는 바꾸지 않음 |

macOS 27 트랩은 수정 전 커밋 `9452aa2`에서도 같은 위치에서 재현되므로 0.5.1 수정의 회귀가 아닙니다. 이 Mac에서 `SpeechAnalyzer.bestAvailableAudioFormat`은 en-US와 ko-KR 모두 16 kHz, 1채널, Int16, interleaved를 반환했고, 이 형식의 `AnalyzerInput`은 정상 생성됐습니다. Float32 표준 형식은 생성 중 트랩했습니다.

## 검사 결과

| 검사 | 결과 |
|---|---|
| `check-app-model.sh` | 57개 통과. 창 전환 검사는 수정을 되돌렸을 때 실패하는 것을 확인 |
| `check-audio-callbacks.sh` | 18개 통과 |
| `check-system-audio.sh` | 통과. 전역 탭, macOS 권한 창, 실제 재생 앱은 실행하지 않음 |
| `CaptionCoreChecks` | 40개 통과 |
| `check-local-model-store.sh` | 통과. 확인한 모델을 설정 화면이 다시 해시하지 않고, 로드 직전 refresh는 변조를 거절 |
| `check-lifecycle.sh`, `check-glossary-boundaries.sh`, `check-translation-leases.sh`, `check-prompt-safety.sh` | 통과 |
| `check-local-polish.sh` | 수명 주기 검사 통과 |
| `check-dictionary-translation.sh` | 실행됨. 의미 검토는 하지 않았고 저장소의 기존 원자료는 덮어쓴 것을 복원 |
| [`check-continuous-pipeline.sh`](raw/continuous-pipeline-20261008T015647Z-96113.json) | `passed=true`, 합성 음성 1,830초, 확정 451개, 실패 0건. ASR 지연 p50 0.205초·p95 0.800초, 앱 프로세스 RSS 최고 30.4 MB(Apple 언어 서비스 제외) |
| [`check-bidirectional-polish-pipeline.sh`](raw/bidirectional-polish-pipeline-20261008-112806-D86C1E86.json) | `passed=true` |

연속 입력과 양방향 검사는 합성 음성 파일을 실제 Apple 음성 인식과 제품 상태 경로에 공급한 결과입니다. 실제 마이크 정확도나 사람의 체감 지연을 뜻하지 않습니다.

## 실행하지 않았거나 확인하지 못한 것

- 새 정지 버튼, 대화상자, 큰 창 하단 배치는 화면으로 확인하지 못했습니다. `--snapshot` 미리보기 렌더링이 이 환경에서 파일을 만들지 못했습니다. 모델 상태 검사만 통과했습니다.
- 큰 창과 작은 창 사이의 실제 이동은 앱 모델 검사로 "작은 창을 요청하는지"만 확인했고, 창이 실제로 바뀌는지는 사람이 확인해야 합니다.
- `check-realtime-pipeline.sh`는 영어 음성 파일을 인자로 받아야 해서 실행하지 않았습니다. `check-dictionary-realtime.sh`는 같은 이름의 기존 보고서를 덮어쓰지 않으려고 거절했습니다. UI soak는 실행하지 않았습니다.
- 실제 마이크, 전체 출력 탭의 권한 창, macOS 26.4 실기기는 확인하지 않았습니다.

## 새로 발견한 항목

문장 다듬기 모델 로드가 이 Mac에서 약 15초입니다. `check-local-polish.sh`의 `coldLoad_ms`는 15,105, 양방향 검사의 `local_model_load_ms`는 15,188로, 별도 프로세스 두 번에서 같았습니다. 같은 구간(`engine.prepare`, 해시 제외)의 이전 기록은 macOS 26.7에서 686~1,261 ms였습니다. 10월 2일 계측 보고서 하나에도 15,276 ms가 있어서 macOS 27 때문이라고 단정할 수 없고, 원인은 확인하지 못했습니다. 다듬기를 켠 사용자는 앱을 켠 뒤 이 시간만큼 시작 버튼이 잠긴 상태로 기다릴 수 있습니다.

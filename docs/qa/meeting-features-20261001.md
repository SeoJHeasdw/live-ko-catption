# 컴퓨터 소리 입력, 발표 화면 위 표시, 방향 전환, 용어집 — 2026-10-01

대상은 0.4.8 (16)부터 0.4.11 (19)까지의 커밋 `203e097`, `e624b49`, `7fba976`, `1eb5e6b`입니다. 웹에서 재생되는 영어를 자막으로 보는 용도와, 발표는 영어로 하고 질문은 한국어로 나오는 자리를 위한 기능입니다.

네 기능 모두 자동 검사는 통과했지만, **실제 앱에서 사람이 확인해야 하는 부분이 남아 있습니다.** 아래 "확인하지 않은 것"을 먼저 읽으세요.

## 검사 결과

| 검사 | 결과 |
|---|---|
| `swift run --build-system native CaptionCoreChecks` | 28개 통과 |
| `swift run --build-system native TranslationSchedulingChecks` | 7개 통과 |
| `./scripts/check-app-model.sh` | 46개 통과 |
| `./scripts/check-audio-callbacks.sh` | 10개 통과 |
| `./scripts/check-system-audio.sh` | 5개 통과 |
| `./scripts/check-lifecycle.sh`, `check-translation-leases.sh`, `check-local-model-store.sh` | 통과 |
| `./scripts/check-realtime-pipeline.sh` (235wpm 합성 영어) | 통과, 묶음의 최신 원문 → 번역 중앙값 91ms |
| `./scripts/check-bidirectional-polish-pipeline.sh` | 공개 합성 예문 4개 통과 |
| `./scripts/check-ui-soak.sh 35 … --ui-soak-compact --ui-soak-sidebar` | 통과 |

## 컴퓨터 소리 입력

`check-system-audio.sh`는 합성 예문을 `afplay`로 재생하고, 그 프로세스 하나만 탭해 탭하는 동안 음소거합니다. 제품의 `AudioCapture`·`AudioPump`와 설치된 영어 인식기를 그대로 사용합니다.

- 탭한 예문 전체가 인식기에 도착했습니다.
- 재생이 끝난 뒤 캡처를 계속 켜 둔 상태에서 마지막 문장이 약 0.3초 뒤 확정됐습니다. 탭은 재생이 끝나면 버퍼를 보내지 않거나 무음만 보내므로, 무음을 채우지 않으면 이 확정이 나오지 않습니다.
- 재생 중과 조용함의 상태 전환이 보고됐고 입력 오류는 없었습니다.
- 정지 후 비공개 탭 장치가 제거됐습니다.

별도 임시 실행에서 전체 출력 탭이 작은 음량의 재생을 받는 것(3초에 100ms 버퍼 32~33개)과, 아무것도 재생하지 않을 때는 버퍼가 0개인 것을 확인했습니다. 출력 장치를 집합 장치에 묶어도 조용할 때 버퍼가 오지 않아 탭만 담는 구성으로 뒀습니다.

검사를 만들던 중, 무음 타이머 핸들러를 `@MainActor` 메서드 안에서 만들면 첫 실행에서 프로세스가 종료되는 것을 발견해 `AudioPump.makeSilenceTimer()`로 옮겼습니다.

## 대화 중 방향 전환

주입한 번역기로 세 가지를 확인합니다: 일시정지 중 전환이 이전 자막을 보존하고 구절마다 자기 언어 표시로 저장되는지, 설치되지 않은 언어로는 전환하지 않고 이유를 표시하는지, 듣는 중 전환이 마지막 문장을 확정한 뒤 반대 방향으로 정확히 한 번 다시 시작하는지.

설치된 자산으로 인식기·번역기를 준비하는 시간은 한국어·영어를 번갈아 4회 쟀을 때 134, 55, 54, 46ms였습니다. 정지와 마이크 재시작을 포함한 전체 전환 시간은 재지 않았습니다.

## 용어집

- **인식기 용어 힌트는 효과가 없었습니다.** 제품·회사 이름 일곱 개가 든 합성 영어 문장을 `SpeechTranscriber`에 넣고 `AnalysisContext.contextualStrings`를 준 경우와 주지 않은 경우를 비교했을 때 받아쓰기가 글자까지 같았습니다. 그래서 사용자가 적은 잘못 들리는 표기를 원문에서 고쳐 쓰는 방식을 넣었습니다.
- **다듬기 모델은 용어를 대체로 따랐습니다.** 실제 1.8B로 가상의 이름이 든 세 문장을 IT 분야와 내 용어집 분야로 번역했습니다.

| 원문 | IT 분야 | 내 용어집 (`Northwind = 노스윈드`, `workload = 워크로드`, `Granite`, `WebSphere Liberty`) |
|---|---|---|
| We will deploy the order service on WebSphere Liberty and review the Granite model results for Northwind. | `Northwind`를 그대로 둠 | `노스윈드`로 옮김. `Liberty` 뒤에 한자 한 글자가 섞임 |
| The Northwind workload moves to Liberty next quarter. | `작업량`, `Northwind` | `워크로드`, `노스윈드`. 용어집에 없는 `Liberty`는 `리버티`로 옮김 |
| Granite handles the summarization workload. | `그랜이트` | `Granite`. `workload`는 `작업`으로 옮겨 용어를 따르지 않음 |

한자가 섞인 출력은 이후 원문에 없는 한자를 거부하는 검사를 추가해, 이런 경우 빠른 번역을 유지하도록 했습니다. 문장 세 개의 관찰이며 용어 준수율을 보장하지 않습니다.

## 확인하지 않은 것

- 실제 앱에서 **컴퓨터에서 나는 소리**를 골랐을 때의 macOS 권한 요청과, 브라우저·영상·회의 앱의 실제 재생.
- 재생 도중 출력 장치를 바꿀 때(예: 이어폰 연결)의 동작.
- 간략 창이 실제 PowerPoint·Keynote 슬라이드쇼 위에 뜨는지, 그 층에서 호버 도움말이 보이는지.
- 실제 마이크로 방향을 바꿀 때 걸리는 전체 시간과 그 사이에 놓치는 말.
- 실제 발표 용어로 채운 용어집의 효과. 용어집 파일은 비어 있습니다.
- 여러 사람이 번갈아 말하는 회의실 음향에서의 인식 품질.

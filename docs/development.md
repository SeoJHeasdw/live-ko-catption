# 개발 가이드

Live Korean Captions는 Apple Silicon과 macOS 26.4 이상을 대상으로 하는 독립 macOS 앱입니다. SwiftUI·AppKit으로 화면을 구성하고, Apple의 기기 내 음성 인식·번역을 사용합니다. 선택적 문장 보완은 앱에 포함된 C++/Metal 런타임으로 실행합니다.

사용 방법은 [README](../README.md), 기존 검사 결과는 [검증 자료 안내](qa/README.md)를 참고하세요.

## 빌드

macOS 26.4 이상을 지원하는 SDK, Swift 6 이상의 도구, Python 3가 필요합니다. Xcode 또는 Command Line Tools를 설치한 환경에서 다음 명령을 실행합니다.

```sh
./scripts/build-app.sh
open "dist/Live Korean Captions.app"
```

빌드 스크립트는 `swift build --build-system native`로 릴리스 실행 파일을 만들고 독립 `.app` 번들을 구성합니다. 번들과 포함된 런타임에는 로컬 실행용 임시 서명을 적용합니다. App Store 제출, Developer ID 서명, 공증은 포함하지 않습니다.

외부 Swift 패키지 의존성은 없습니다. 네이티브 런타임 빌드는 고정된 llama.cpp 소스와 아카이브 SHA-256을 사용하며, 처음 빌드할 때 필요한 항목을 다운로드합니다. cmake·ninja는 `.build/tools/local-runtime`에 설치합니다. 런타임의 핀, ABI, 취소 동작과 외부 라이선스는 [Runtime/README.txt](../Runtime/README.txt)에 정리돼 있습니다.

| 위치 | 내용 |
|---|---|
| `dist/Live Korean Captions.app` | 실행 가능한 앱 번들 |
| `.build/local-runtime/libcaption_local_translation.dylib` | 앱에 포함되는 네이티브 보완 런타임 |
| `.build/local-runtime/caption-local-benchmark` | 로컬 모델 검사 도구 |
| `.build/tools/local-runtime` | 프로젝트 전용 빌드 도구 |

모델 가중치는 빌드에 포함하지 않습니다. 앱의 명시적 다운로드로 설치하며, 선택 모델이 없어도 Apple 자막 경로를 사용할 수 있습니다.

## 코드 구조

| 위치 | 역할 |
|---|---|
| [Sources/CaptionCore](../Sources/CaptionCore) | 자막 구간, 원문 수정 버전, 확정 상태, 문맥 묶음, 텍스트 내보내기와 번역 큐 |
| [CaptionModel.swift](../Sources/LiveKoCaption/CaptionModel.swift) | 언어 자산 준비, 음성 인식·번역 작업, 대화 생명주기와 오류 복구 |
| [AudioDeviceCapture.swift](../Sources/LiveKoCaption/AudioDeviceCapture.swift) | 선택한 장치에 고정하는 입력 전용 AudioUnit 캡처 |
| [AudioCapture.swift](../Sources/LiveKoCaption/AudioCapture.swift) | 장치 목록, 입력 버퍼 복사, 변환과 분석 스트림 |
| [CaptionView.swift](../Sources/LiveKoCaption/CaptionView.swift) | 상세 자막 화면, 접이식 조작 사이드바, 설정 팝업과 하단 실행 버튼 |
| [CompactCaptionView.swift](../Sources/LiveKoCaption/CompactCaptionView.swift) | 떠 있는 간략 자막 창의 조작 UI |
| [NativeCaptionTranscript.swift](../Sources/LiveKoCaption/NativeCaptionTranscript.swift) | 최근 표시 구절의 네이티브 텍스트 화면과 읽기 위치 유지 |
| [NativeCompactCaption.swift](../Sources/LiveKoCaption/NativeCompactCaption.swift) | 간략 창의 최근 자막과 긴 문장 끝부분 표시 |
| [CaptionWindowCoordinator.swift](../Sources/LiveKoCaption/CaptionWindowCoordinator.swift) | 같은 대화 모델을 유지하는 보기 전환과 창 상태 |
| [TranslationSessionLease.swift](../Sources/LiveKoCaption/TranslationSessionLease.swift) | Apple 번역 요청의 실제 반환과 세션 정리 추적 |
| [LocalModelStore.swift](../Sources/LiveKoCaption/LocalModelStore.swift) | 선택 모델 다운로드, 크기·SHA-256 검증과 설치 |
| [LocalTranslationEngine.swift](../Sources/LiveKoCaption/LocalTranslationEngine.swift) | 네이티브 모델 로딩, 직렬 추론, 작업별 취소와 시간 제한 |
| [Runtime](../Runtime) | 고정 llama.cpp/ggml을 정적으로 연결하는 C++/Metal 런타임 |
| [Tests](../Tests) | 상태·스케줄링·앱 모델·오디오·실제 엔진 검사와 공개 예문 |

## 화면과 입력 장치

상세 화면의 얇은 상단 도구막대에는 제목·번역 방향·사이드바 접기/펼치기가 있습니다. 왼쪽 조작 사이드바는 펼치면 260pt, 접으면 56pt의 아이콘 열로 표시합니다. 간략 보기·전체 화면·기록 저장·새 대화·설정은 두 상태에서 모두 사용할 수 있으며, 아이콘에 마우스 호버 설명과 접근성 이름을 제공합니다. 실행·일시정지·재개 버튼은 하단에 유지합니다.

사이드바의 폭과 라벨은 0.22초 동안 전환하며, macOS의 동작 줄이기가 켜져 있으면 애니메이션을 생략합니다. 접힘 상태는 사용자 설정으로 보존합니다. 자막 영역은 사이드바의 폭에 맞춰 확장되고 최근 자막·대화 모델은 유지합니다.

펼친 사이드바의 **번역 분야**는 일반·IT를 선택하는 사전 설정입니다. 비어 있는 시작 전 대화에서는 문장 다듬기의 활성화 여부와 관계없이 선택할 수 있습니다. 기록이 있거나 실행·준비 중이면 현재 분야를 유지하고 새 대화에서 변경하도록 안내합니다. 분야는 `LocalTranslationRequest`의 로컬 모델 프롬프트에만 전달하며, Apple의 빠른 번역에는 적용하지 않습니다.

사이드바의 설정 아이콘은 **자막·번역·마이크** 탭이 있는 팝업을 엽니다. 자막 탭의 **원문 함께 보기**는 현재 방향의 입력 언어를 표시하며, **자막 글자 크기**를 바꾸면 원문 크기도 함께 조절합니다. 번역 탭에는 **최근 구절 함께 번역**과 선택적 **문장 다듬기**가 있습니다. 언어 자산이 준비되지 않았을 때는 빈 자막 화면 중앙의 **언어 모델 준비** 버튼으로 다운로드를 시작합니다.

마이크 기본값은 **자동 선택 (시스템 기본)**이며, 빈 장치 UID로 표현합니다. 장치 목록은 설정 팝업을 열 때, 마이크 탭으로 이동할 때, 자막을 시작할 때 갱신합니다. 자동 선택은 각 시작 시 현재 시스템 기본 마이크를 사용합니다. 수동 선택은 저장한 장치 UID로 입력을 고정하며, 해당 장치가 없으면 기본 마이크로 몰래 전환하지 않고 오류를 표시합니다.

실행 중 시스템 기본 마이크가 바뀌거나 새 장치가 연결돼도 자동으로 입력을 전환하지 않습니다. 입력을 바꾸려면 일시정지한 뒤 설정을 변경하고 재개합니다. 현재 입력이 끊기는 경우는 오디오 오류 복구 경로를 따릅니다.

## 유지해야 할 동작

### 자막과 번역

- 한 대화는 시작 전에 선택한 영어→한국어 또는 한국어→영어 방향을 유지합니다.
- 회색 자막은 수정 가능한 초안입니다. 음성 인식 원문이 확정되고 정확한 현재 수정 버전이 번역됐을 때만 최종 상태가 됩니다.
- 이전 수정 버전, 취소된 작업, 이전 대화의 결과는 최신 자막을 덮어쓰지 않습니다.
- 초안 작업은 최신 상태로 합치고 확정 원문을 우선합니다. 전체 세션 기록을 매번 재번역하지 않습니다.
- 문맥 보정은 인접한 2~4개 구절, 12초, 원문 500자 이내의 제한된 묶음입니다. 긴 무음과 일시정지를 넘어 묶지 않으며, 오래된 문맥 묶음을 반복 수정하지 않습니다.
- 선택 모델은 확정된 원문만 보완합니다. 빠른 Apple 결과를 표시하면서 다음 확정 원문에 우선권을 주고, 지연·실패 시 빠른 결과를 유지합니다.
- 새 미확정 원문도 선택 보완·문맥 작업보다 우선합니다. 다음 초안이 대기 중이면 앞 구절의 선택 보완을 시작하지 않습니다.
- 음성 인식은 여러 수정본을 몇 ms 안에 한꺼번에 전달합니다. 초안은 원문 갱신이 50ms 동안 멈추면 최신 수정본만 번역하고, 갱신이 끊이지 않아도 150ms 안에 번역을 시작합니다. 확정 원문은 이 대기를 건너뛰고 먼저 처리합니다.
- 상세·간략 자막의 네이티브 갱신은 직전 갱신에서 1/30초가 지났으면 바로 그리고, 그 안의 연속 갱신은 최신 내용 하나로 묶습니다. 상세 화면의 최신 따라가기 스크롤은 0.2초 간격을 유지합니다.
- 문맥 작업은 마지막 원문 구절이 확정되고 750ms 동안 새 원문 갱신이 없을 때 시작합니다. 뒤에 미확정 구절이 있으면 이전 문맥 작업을 대기열에 다시 넣지 않습니다.
- IT 분야는 해당 원문에 관련된 제한된 용어를 프롬프트에 제공합니다. 인식·번역 결과를 임의의 단어 치환으로 덮어쓰지 않습니다.

간략 창은 문맥 묶음 대신 최근 개별 구절의 번역을 표시합니다. 다음 번역이 대기 중이면 같은 대화의 최근 읽을 수 있는 자막을 유지하며, 검색 범위는 최근 원문 100개로 제한합니다. 새 대화에서는 이전 자막을 비웁니다. 기본 창 크기는 780×224이며 최소 크기 420×144를 유지합니다. 자막은 창 높이 전체를 사용하고, 미확정 자막은 계속 회색으로 갱신합니다. 네이티브 문서 갱신은 같은 앞 구절을 유지한 채 바뀐 뒤쪽만 교체합니다. 위쪽에 반 줄이 남지 않도록 완전한 줄에 맞춰 스크롤하고, 한국어는 단어 경계를 우선해 줄바꿈합니다. 필요한 아래 여백은 네이티브 문서 안에서만 조절합니다.

### 오디오와 작업 생명주기

오디오 콜백에서는 인식·번역을 실행하지 않습니다. 버퍼를 복사한 뒤 제한된 변환 큐로 전달합니다. 변환 대기는 입력 0.5초 이내, 분석 스트림은 8개 버퍼로 제한하며 누락 횟수를 보고합니다. 짧은 입력은 변환 큐에서 약 100ms 단위로 모읍니다. 정지할 때 마지막 짧은 입력도 배출합니다.

AVFoundation의 외부 스레드 콜백은 nonisolated factory인 `AudioPump.makeTapBlock()`과 `AudioCallbackBridge`로 구성합니다. MainActor 메서드 안에서 `AVAudioNodeTapBlock`을 만들면 Swift 6이 MainActor 실행을 요구하도록 추론할 수 있어 실제 마이크 입력에서 충돌할 수 있습니다. 오디오 변경 뒤에는 `check-audio-callbacks.sh`를 실행합니다.

Swift 작업 취소를 네이티브 작업의 종료로 취급하지 않습니다. Apple 번역은 실제 응답이 반환된 뒤 세션을 정리합니다. 선택 런타임은 작업 ID로 취소하고, 실행 중인 네이티브 호출이 끝나기 전에 모델이나 라이브러리를 해제하지 않습니다.

첫 입력·입력 복구 대기는 20초입니다. 번역 6초, 문맥 보정 4초, 정지 정리 8초는 오류 복구의 대기 한도입니다. 선택 보완은 네이티브 1.5초와 앱 1.8초의 제한을 사용합니다. 진행 중인 GPU 연산은 반환될 때까지 기다려야 하므로 네이티브 제한은 절대적인 종료 시각을 보장하지 않습니다. 이 값들은 정상 자막의 전체 지연이나 성능 보장이 아닙니다.

### 로컬 모델과 데이터

초기 자산 준비 후 추론은 로컬에서 실행합니다. 이 앱은 다른 프로젝트의 설정·의존성·모델 서버·실행 스크립트와 분리합니다. 클라우드 번역이나 시스템 오디오 캡처를 추가하지 않습니다.

선택 모델은 `~/Library/Application Support/Live Korean Captions/Models/`에 설치합니다. [모델 manifest](../Resources/local-model-manifest.json)와 [검증 상수](../Sources/LiveKoCaption/LocalModelStore.swift)의 고정 파일 크기·SHA-256을 확인한 뒤 원자적으로 설치합니다. 가중치는 Git과 앱 번들에서 제외합니다.

대화는 자동 저장하지 않습니다. 앱 종료·업데이트·새 대화 전에 필요한 기록을 수동 저장합니다. 실제 사용자 대화와 원본 음성을 공개 fixture, 스크린샷, QA 자료에 옮기지 않습니다.

## 검사 명령

명령은 저장소 루트에서 실행합니다. 아래 검사들은 빌드 도구를 사용하지만 실제 마이크를 열거나 모델 가중치를 내려받지는 않습니다.

```sh
swift run --build-system native CaptionCoreChecks
swift run --build-system native TranslationSchedulingChecks
./scripts/check-app-model.sh
./scripts/check-lifecycle.sh
./scripts/check-audio-callbacks.sh
./scripts/check-translation-leases.sh
./scripts/check-local-model-store.sh
```

| 검사 | 범위 |
|---|---|
| `CaptionCoreChecks` | 수정 버전, 회색→최종 조건, 늦은 결과 거부, 문맥 묶음과 내보내기 |
| `TranslationSchedulingChecks` | 최신 초안 유지, 확정 원문 우선 처리와 중복 방지 |
| `check-app-model.sh` | 주입한 번역기로 취소, 시간 초과, 재시도, 보완과 원문 보존 재현 |
| `check-lifecycle.sh` | 작업의 시간 제한과 취소 처리 |
| `check-audio-callbacks.sh` | 콜백 실행 영역, PCM 변환, 종료 시 입력 배출 |
| `check-translation-leases.sh` | 실제 반환 전 세션 보존과 요청 상한 |
| `check-local-model-store.sh` | 다운로드 취소, 크기·해시 검사와 설치 처리 |

자막 상태나 번역 스케줄링을 바꾸면 `CaptionCoreChecks`를 실행합니다. 오디오 코드를 바꾸면 `check-audio-callbacks.sh`를 실행하고, 변경 범위에 맞는 추가 검사를 선택합니다. 새 SDK API는 실제 최소 OS 버전을 확인해 macOS 26.4에서 사용할 수 있는지 검토합니다.

### 준비된 Apple 엔진 검사

해당 언어 자산을 앱에서 먼저 준비하세요. 다음 파일 검사는 마이크를 열거나 언어 모델을 다운로드하지 않습니다.

```sh
swift run --build-system native LocalPipelineCheck /absolute/path/to/english-audio.aiff
./scripts/check-audio-callbacks.sh /absolute/path/to/english-audio.aiff
./scripts/check-realtime-pipeline.sh /absolute/path/to/english-audio.aiff \
  --output /tmp/caption-report.json
swift run --build-system native LocalPipelineCheck --translation-quality --compare-strategies
```

파일 처리 시간, 네이티브 번역 호출 시간, 실제 시간에 맞춘 스트리밍 관찰은 서로 다른 측정입니다. 파일 검사만으로 마이크 하드웨어·사람 발음·소음·화면 표시를 검증했다고 판단하지 않습니다.

### 선택 모델 검사

앱의 다운로드 기능으로 검증된 모델을 설치하고, 앱 빌드로 런타임을 준비한 뒤 실행합니다.

```sh
./scripts/check-local-polish.sh \
  --model "$HOME/Library/Application Support/Live Korean Captions/Models/Hy-MT2-1.8B-Q6_K.gguf" \
  --runtime .build/local-runtime/libcaption_local_translation.dylib \
  --fixtures Tests/LocalPolishChecks/fixtures.json \
  --output /tmp/local-polish.json
./scripts/check-bidirectional-polish-pipeline.sh /tmp/bidirectional-polish.json
```

첫 명령은 공개 텍스트 예문 비교입니다. `--soak-seconds 1800`을 추가하면 네이티브 번역을 약 2초 간격으로 반복합니다. 마이크·화면·팬 소음의 30분 검사가 아닙니다.

두 번째 명령은 설치된 macOS 음성 Samantha·Yuna로 공개 예문 파일을 합성해 양방향의 실제 음성 인식·Apple 번역·선택 모델 경로를 검사합니다. 모델·런타임·언어 자산·음성을 새로 다운로드하지 않습니다. 모델과 런타임 경로는 `CAPTION_PIPELINE_MODEL_PATH`, `CAPTION_PIPELINE_RUNTIME_PATH`로 지정할 수 있습니다.

### 연속 엔진 및 화면 검사

```sh
./scripts/check-continuous-pipeline.sh
./scripts/check-ui-soak.sh
./scripts/check-ui-soak.sh 65 /tmp/compact-caption-ui.jsonl --ui-soak-compact
./scripts/check-ui-soak.sh 65 /tmp/sidebar-caption-ui.jsonl --ui-soak-compact --ui-soak-sidebar
```

앞의 두 명령은 기본 30분 검사입니다. 엔진 검사는 합성 영어 파일을 실제 시간에 맞춰 입력한 뒤 30초 재시작을 확인합니다. 화면 검사는 별도 번들 ID의 시험 앱으로 합성 자막을 갱신하며 창 크기·글자 크기·원문 표시를 바꿉니다. 세 번째 명령은 짧은 간략 창 검사입니다. `--ui-soak-sidebar`는 입력 중 사이드바 전환과 폭 변경 후 최신 자막·읽던 구절·텍스트 선택 유지도 확인합니다. 합성 화면 검사는 실제 마이크 정확도와 번역 지연을 측정하지 않습니다.

## 화면 미리보기와 실제 사용 확인

```sh
open "dist/Live Korean Captions.app" --args --preview
```

미리보기는 예시 대화임을 명시하며 실제 음성 인식·번역 결과나 측정 성능을 표시하지 않습니다.

실제 사용 확인은 목표 마이크와 화자로 진행합니다. 짧은 구절·긴 문장, 문장 중간의 부정, 숫자·단위·요일 정정·고유명사·전문 용어를 기준 원문과 대조합니다. 일시정지·재개·새 대화·저장을 확인하고, 언어 자산 준비 후 네트워크를 끈 실행과 20~30분 연속 입력을 별도로 점검합니다.

하단의 **처리 시간**에서 확인하는 자막 도착·음성 인식 시간은 음성 구간 끝을 기준으로 한 추정값이며 마이크 하드웨어 지연은 포함하지 않습니다. 번역 호출 시간은 개별 텍스트 번역 작업의 시간입니다. 개별 호출 시간이나 상태 검사 통과를 실제 전체 지연·의미 정확도의 증거로 사용하지 않습니다.

## 변경과 검증 기록

기능별로 빌드 가능한 커밋을 만들고 완료한 기능을 각각 푸시합니다. 커밋 메시지는 한국어로 작성합니다. 저장소의 [AGENTS.md](../AGENTS.md)에 있는 프로젝트 지침을 따릅니다.

QA 자료에는 검사 날짜, 실행 조건, 대상 소스·바이너리 식별, 검사 범위와 한계를 함께 기록합니다. 초기 실패와 후속 성공을 구분하고 기존 원자료를 덮어쓰지 않습니다. 이전 결과를 현재 코드 전체의 검증으로 바꾸어 설명하지 않습니다.

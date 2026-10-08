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
| [Sources/CaptionCore](../Sources/CaptionCore) | 자막 구간, 원문 수정 버전, 확정 상태, 문맥 묶음, 텍스트 내보내기, 번역 큐와 사용자 용어집 |
| [CaptionModel.swift](../Sources/LiveKoCaption/CaptionModel.swift) | 언어 자산 준비, 음성 인식·번역 작업, 대화 생명주기와 오류 복구 |
| [AudioDeviceCapture.swift](../Sources/LiveKoCaption/AudioDeviceCapture.swift) | 선택한 장치에 고정하는 입력 전용 AudioUnit 캡처, 컴퓨터 소리를 받는 비공개 탭 장치 |
| [AudioCapture.swift](../Sources/LiveKoCaption/AudioCapture.swift) | 장치 목록, 입력 버퍼 복사, 변환과 분석 스트림 |
| [CaptionView.swift](../Sources/LiveKoCaption/CaptionView.swift) | 상세 자막 화면, 접이식 조작 사이드바, 설정 팝업과 하단 실행 버튼 |
| [CompactCaptionView.swift](../Sources/LiveKoCaption/CompactCaptionView.swift) | 떠 있는 간략 자막 창의 조작 UI |
| [NativeCaptionTranscript.swift](../Sources/LiveKoCaption/NativeCaptionTranscript.swift) | 최근 표시 구절의 네이티브 텍스트 화면과 읽기 위치 유지 |
| [NativeCompactCaption.swift](../Sources/LiveKoCaption/NativeCompactCaption.swift) | 간략 창의 최근 자막과 긴 문장 끝부분 표시 |
| [CaptionWindowCoordinator.swift](../Sources/LiveKoCaption/CaptionWindowCoordinator.swift) | 같은 대화 모델을 유지하는 보기 전환과 창 상태 |
| [TranslationSessionLease.swift](../Sources/LiveKoCaption/TranslationSessionLease.swift) | Apple 번역 요청의 실제 반환과 세션 정리 추적 |
| [LocalModelStore.swift](../Sources/LiveKoCaption/LocalModelStore.swift) | 선택 모델 다운로드, 크기·SHA-256 검증과 설치 |
| [LocalTranslationEngine.swift](../Sources/LiveKoCaption/LocalTranslationEngine.swift) | 네이티브 모델 로딩, 모델 크기별 프롬프트 형식 선택, 직렬 추론, 작업별 취소와 시간 제한 |
| [Runtime](../Runtime) | 고정 llama.cpp/ggml을 정적으로 연결하는 C++/Metal 런타임 |
| [Tests](../Tests) | 상태·스케줄링·앱 모델·오디오·실제 엔진 검사와 공개 예문 |

## 화면과 입력 장치

상세 화면의 얇은 상단 도구막대에는 제목·번역 방향·사이드바 접기/펼치기가 있습니다. 왼쪽 조작 사이드바는 펼치면 260pt, 접으면 56pt의 아이콘 열로 표시합니다. 간략 보기·전체 화면·기록 저장·새 대화·설정은 두 상태에서 모두 사용할 수 있으며, 아이콘에 마우스 호버 설명과 접근성 이름을 제공합니다. 실행·일시정지·재개 버튼은 하단에 유지합니다.

사이드바의 폭과 라벨은 0.22초 동안 전환하며, macOS의 동작 줄이기가 켜져 있으면 애니메이션을 생략합니다. 접힘 상태는 사용자 설정으로 보존합니다. 자막 영역은 사이드바의 폭에 맞춰 확장되고 최근 자막·대화 모델은 유지합니다.

사이드바의 **용어사전 적용**에는 선택한 사전 요약과 번역 설정 버튼을 표시합니다. 설정에서는 AI·IBM·금융권과 개인 사전을 함께 선택합니다. 비어 있는 시작 전 대화에서는 문장 다듬기의 활성화 여부와 관계없이 선택할 수 있습니다. 기록이 있거나 실행·준비 중이면 현재 선택을 유지하고 새 대화에서 변경하도록 안내합니다. 분야/번역 용어는 `LocalTranslationRequest`의 로컬 모델 프롬프트에만 전달하며, 개인 사전의 직접 지정 오인식 표기만 빠른 번역 전에 원문에 적용합니다.

사이드바의 설정 아이콘은 **자막·번역·입력** 탭이 있는 팝업을 엽니다. 자막 탭의 **원문 함께 보기**는 현재 방향의 입력 언어를 표시하며, **자막 글자 크기**를 바꾸면 원문 크기도 함께 조절합니다. 번역 탭에는 **최근 구절 함께 번역**과 선택적 **문장 다듬기**가 있습니다. 언어 자산이 준비되지 않았을 때는 빈 자막 화면 중앙의 **언어 모델 준비** 버튼으로 다운로드를 시작합니다.

입력 기본값은 **마이크 · 자동 선택 (시스템 기본)**이며, 빈 장치 UID로 표현합니다. 장치 목록은 설정 팝업을 열 때, 입력 탭으로 이동할 때, 자막을 시작할 때 갱신합니다. 자동 선택은 각 시작 시 현재 시스템 기본 마이크를 사용합니다. 수동 선택은 저장한 장치 UID로 입력을 고정하며, 해당 장치가 없으면 기본 마이크로 몰래 전환하지 않고 오류를 표시합니다.

실행 중 시스템 기본 마이크가 바뀌거나 새 장치가 연결돼도 자동으로 입력을 전환하지 않습니다. 입력을 바꾸려면 일시정지한 뒤 설정을 변경하고 재개합니다. 현재 입력이 끊기는 경우는 오디오 오류 복구 경로를 따릅니다.

**컴퓨터에서 나는 소리**는 `AudioInputDevice.systemAudioUID`로 저장하는 선택입니다. 시작할 때 `SystemAudioTap`이 이 Mac의 전체 출력을 받는 비공개 Core Audio 탭과 그 탭만 담은 비공개 집합 장치를 만들고, 기존 `AudioDeviceCapture`가 그 장치를 마이크처럼 읽습니다. 마이크는 열지 않으며 마이크 권한도 요청하지 않습니다. macOS는 `NSAudioCaptureUsageDescription`으로 시스템 오디오 녹음 허용을 따로 묻습니다. 정지하면 장치와 탭을 제거합니다.

## 유지해야 할 동작

### 자막과 번역

- 번역 방향은 시작 전에 선택하고, 대화 도중에는 `CaptionModel.switchDirection()`으로만 바꿉니다. 듣는 중이면 현재 실행을 정상 정지해 마지막 문장을 정리한 뒤 반대 방향으로 다시 시작합니다. 설치된 언어 자산이 없으면 바꾸지 않고 이유를 표시하며, 전환이 다운로드를 시작하지는 않습니다. 말소리로 언어를 추정하지 않습니다.
- 빈 대화를 처음 시작할 때만 간략 창으로 전환합니다(`latestStartBeganConversation`). 일시정지 뒤 재개와 방향 전환의 재시작은 사용자가 보고 있는 창을 그대로 둡니다.
- 큰 창과 간략 창 모두 ⏸ 일시정지·재개와 ■ 정지를 같은 짝으로 둡니다. 일시정지는 같은 대화를 이어 쓰는 동작이고, 정지(⌘.)는 소리 입력을 멈춘 뒤 상세 창에서 "저장 후 새 대화 / 저장하지 않고 새 대화 / 일시정지 상태로 두기"를 묻습니다. 정지 자체는 기록을 지우지 않으며, 켜짐 조건은 `CaptionModel.canEndConversation`입니다.
- 각 `CaptionSegment`는 인식된 때의 `direction`을 보존합니다. 저장 기록은 구절마다 자기 언어 표시를 쓰고, 실패한 구절의 다시 번역은 현재 방향의 구절에만 적용합니다. 실행 경계를 넘는 문맥 묶음은 만들지 않으므로 방향이 다른 구절이 한 묶음이 되지 않습니다.
- 회색 자막은 수정 가능한 초안입니다. 음성 인식 원문이 확정되고 정확한 현재 수정 버전이 번역됐을 때만 최종 상태가 됩니다.
- 이전 수정 버전, 취소된 작업, 이전 대화의 결과는 최신 자막을 덮어쓰지 않습니다.
- 초안 작업은 최신 상태로 합치고 확정 원문을 우선합니다. 전체 세션 기록을 매번 재번역하지 않습니다.
- 문맥 보정은 인접한 2~4개 구절, 12초, 원문 500자 이내의 제한된 묶음입니다. 긴 무음과 일시정지를 넘어 묶지 않으며, 오래된 문맥 묶음을 반복 수정하지 않습니다.
- 선택 모델은 확정된 원문만 보완합니다. 빠른 Apple 결과를 회색으로 표시한 뒤 실시간 번역과 분리된 작업 줄에서 보완하므로, 다음 초안이나 확정 원문의 빠른 번역을 기다리게 하지 않습니다. 지연·실패 시 빠른 결과를 유지합니다.
- 보완은 한 번에 하나만 실행합니다. 대기는 2문장까지이며, 넘치면 가장 오래 기다린 문장을 빠른 번역으로 확정합니다. 새 초안은 진행 중인 보완을 취소하지 않습니다. 로컬 엔진을 쓰는 문맥 묶음과 보완은 동시에 실행하지 않습니다.
- 새 미확정 원문은 문맥 작업보다 우선합니다.
- 음성 인식은 여러 수정본을 몇 ms 안에 한꺼번에 전달합니다. 초안은 원문 갱신이 50ms 동안 멈추면 최신 수정본만 번역하고, 갱신이 끊이지 않아도 150ms 안에 번역을 시작합니다. 확정 원문은 이 대기를 건너뛰고 먼저 처리합니다.
- 상세·간략 자막의 네이티브 갱신은 직전 갱신에서 1/30초가 지났으면 바로 그리고, 그 안의 연속 갱신은 최신 내용 하나로 묶습니다. 상세 화면의 최신 따라가기 스크롤은 0.2초 간격을 유지합니다.
- 문맥 작업은 마지막 원문 구절이 확정되고 750ms 동안 새 원문 갱신이 없을 때 시작합니다. 뒤에 미확정 구절이 있으면 이전 문맥 작업을 대기열에 다시 넣지 않습니다.
- 선택한 사전에서 해당 원문에 관련된 제한된 용어를 프롬프트에 제공합니다. 인식·번역 결과를 앱이 정한 단어 치환으로 덮어쓰지 않습니다.
- **용어사전 적용**은 `CaptionDictionary` ID 집합으로 여러 분야/개인 파일을 선택합니다. `BuiltInDictionaries`는 AI·IBM·금융권의 공개 공식 용어 62개와 짧은 영어 분야 설명을 제공합니다. 출처: [AI](research/ai-glossary-20261002.md), [IBM](research/ibm-glossary-20261002.md), [금융권](research/finance-glossary-20261002.md). 분야 설명은 공식 `[Background Information]` 형식에, 현재 원문은 `[Source Text]`에 나누어 넣습니다. 원문에 관련된 번역 참고는 최대 8개입니다. 원문 정규화는 한 번 수행하고, 무관한 용어는 정규식 전에 제외하며 8개를 찾으면 멈춥니다. 영어 복수 `s` 및 공백/하이픈, 한국어 띄어쓰기 변형은 참고 용어 매칭에만 사용하고 원문을 치환하지 않습니다.
- 개인 사전은 `~/Library/Application Support/Live Korean Captions/Glossary/`의 UTF-8 `.txt` 파일입니다. 이름/문맥은 `# 이름:`/`# 문맥:` 헤더로 선택적으로 지정하며, 파일당 256 KiB·300개 용어·32개 파일로 제한합니다. 심볼릭 링크는 읽지 않습니다. 번역 대기 중에는 다시 읽지 않고 시작 시 재로딩합니다. 미리보기는 개인 파일과 이름을 읽지 않습니다. 기존 파일과 구 설정을 이행하며, 명시적인 새 빈 선택이 이전 설정보다 우선합니다.
- `DictionaryTerms`는 양방향으로 개인 지정 번역을 공개 용어보다 우선하고, 같은 우선순위의 다른 번역은 제외/표시합니다. `heardAs`는 선택한 개인 파일에 직접 적힌 표기만 사용하며, 같은 별칭의 서로 다른 교정 목적지는 제외합니다. 원래 입력을 압축 radix 인덱스로 검색해 실제 존재하는 완전한 별칭만 한 번 매칭하여 교정의 연쇄 적용과 매 부분 자막의 전체 정규식 순회를 피합니다. 공개 사전은 Apple 빠른 번역에 용어쌍을 전달하거나 원문/번역을 직접 치환하지 않습니다. `AnalysisContext.contextualStrings`는 이전 합성 검사에서 결과를 바꾸지 못해 사용하지 않습니다.
- `TranslationDomain`과 `BuiltInDictionaries.legacy`는 과거 QA fixture의 재현 입력용입니다. 앱 UI와 실제 요청은 사전 목록을 사용합니다. 구 preference `general`은 빈 목록, `it`는 AI, `custom`은 AI와 기존 개인 파일 ID로 이행하며, 누락된 개인 파일 ID는 보존하고 경고합니다.
- 다듬기 출력에 원문에 없는 한자가 섞이면 거부하고 빠른 번역을 유지합니다.

간략 창은 문맥 묶음 대신 최근 개별 구절의 번역을 표시합니다. 다음 번역이 대기 중이면 같은 대화의 최근 읽을 수 있는 자막을 유지하며, 검색 범위는 최근 원문 100개로 제한합니다. 새 대화에서는 이전 자막을 비웁니다. 기본 창 크기는 780×224이며 최소 크기 420×144를 유지합니다. **발표·전체 화면 위에도 간략 창 표시**가 켜져 있으면 창 층을 `CGShieldingWindowLevel() + 1`로 두고, 꺼져 있으면 `.floating`으로 둡니다. 간략 보기로 전환할 때마다 설정을 다시 적용합니다. 자막은 창 높이 전체를 사용하고, 미확정 자막은 계속 회색으로 갱신합니다. 네이티브 문서 갱신은 같은 앞 구절을 유지한 채 바뀐 뒤쪽만 교체합니다. 위쪽에 반 줄이 남지 않도록 완전한 줄에 맞춰 스크롤하고, 한국어는 단어 경계를 우선해 줄바꿈합니다. 필요한 아래 여백은 네이티브 문서 안에서만 조절합니다.

### 오디오와 작업 생명주기

오디오 콜백에서는 인식·번역을 실행하지 않습니다. 버퍼를 복사한 뒤 제한된 변환 큐로 전달합니다. 변환 대기는 입력 0.5초 이내, 분석 스트림은 8개 버퍼로 제한하며 누락 횟수를 보고합니다. 짧은 입력은 변환 큐에서 약 100ms 단위로 모읍니다. 정지할 때 마지막 짧은 입력도 배출합니다.

컴퓨터 소리 탭은 재생 중이 아닐 때 버퍼를 보내지 않거나 디지털 무음만 보냅니다. `AudioPump.makeSilenceTimer()`는 경과 시간과 실제·합성 입력의 누적 프레임 차이만큼 무음을 보충합니다. 타이머 지터가 구간을 빠뜨리지 않으며 합성 무음은 실제 입력 heartbeat를 갱신하지 않습니다. 이 핸들러도 `AudioPump` 안의 nonisolated 위치에서 만듭니다. 상태의 **컴퓨터 소리를 기다리는 중**은 측정 바닥보다 큰 소리가 1.5초 동안 없었다는 표시이며 오류가 아닙니다.

장치 열거·생성·시작·설정 조회·중지·탭 정리는 전용 제어 큐에서 실행합니다. 전역 하드웨어 실행권은 하나이며 실제 정리가 끝날 때까지 유지합니다. 시작 8초·조회 3초·중지 대기 0.8초 안에 호출자에게 반환하되, 늦은 실제 작업은 자동 정리합니다. `CaptionModel`은 비동기 시작 뒤 실행 토큰을 재확인하고 pump의 시간 기준을 사용하므로, 취소된 시작이 현재 대화를 덮거나 장치 생성 대기가 입력 시간에 섞이지 않습니다. 버퍼는 복사 전 예약한 순서대로 변환 큐에서 소비합니다.

AVFoundation의 외부 스레드 콜백은 nonisolated factory인 `AudioPump.makeTapBlock()`과 `AudioCallbackBridge`로 구성합니다. MainActor 메서드 안에서 `AVAudioNodeTapBlock`을 만들면 Swift 6이 MainActor 실행을 요구하도록 추론할 수 있어 실제 마이크 입력에서 충돌할 수 있습니다. 오디오 변경 뒤에는 `check-audio-callbacks.sh`를 실행합니다.

Swift 작업 취소를 네이티브 작업의 종료로 취급하지 않습니다. Apple 번역은 실제 응답이 반환된 뒤 세션을 정리합니다. 선택 런타임은 작업 ID로 취소하고, 실행 중인 네이티브 호출이 끝나기 전에 모델이나 라이브러리를 해제하지 않습니다.

첫 입력·입력 복구 대기는 20초입니다. 번역 6초, 문맥 보정 4초, 정지 정리 8초는 오류 복구의 대기 한도입니다. 선택 보완은 네이티브 1.5초와 앱 1.8초의 제한을 사용합니다. 진행 중인 GPU 연산은 반환될 때까지 기다려야 하므로 네이티브 제한은 절대적인 종료 시각을 보장하지 않습니다. 이 값들은 정상 자막의 전체 지연이나 성능 보장이 아닙니다.

### 로컬 모델과 데이터

초기 자산 준비 후 추론은 로컬에서 실행합니다. 이 앱은 다른 프로젝트의 설정·의존성·모델 서버·실행 스크립트와 분리합니다. 클라우드 번역은 추가하지 않습니다. 컴퓨터 소리는 사용자가 직접 고른 입력만 비공개 Core Audio 프로세스 탭으로 받고, 마이크와 같은 제한된 펌프에 전달하며 파일로 저장하지 않습니다.

선택 모델은 `~/Library/Application Support/Live Korean Captions/Models/`에 설치합니다. [모델 manifest](../Resources/local-model-manifest.json)와 [검증 상수](../Sources/LiveKoCaption/LocalModelStore.swift)의 고정 파일 크기·SHA-256을 확인한 뒤 원자적으로 설치합니다. 가중치는 Git과 앱 번들에서 제외합니다.

모델 refresh는 metadata 캐시만으로 승인하지 않고 매번 전체 SHA-256을 백그라운드에서 다시 확인합니다. 앱 시작은 문장 다듬기가 켜져 있을 때만 모델을 확인·로드하고, 꺼져 있으면 1.47 GB 파일을 읽지 않습니다. 설정 화면은 처음 볼 때 한 번만 `refreshIfNeeded()`로 설치 여부를 확인하며, 모델을 로드하기 전에는 항상 전체 `refresh()`를 거칩니다. 겹친 요청은 같은 읽기를 공유하며, 열린 파일과 경로의 inode·device·mtime·ctime을 대조합니다. 개인 사전은 문자 수 외 scalar·UTF-8 byte와 제어 문자를 검증하고, 교정 결과가 65,536바이트를 넘으면 원 ASR을 유지해 알립니다. 모델 역할 토큰이 포함된 원문은 선택 보완을 생략하고 빠른 번역을 유지합니다. 네이티브 입력은 길이 기반 `lc_translate_bytes`로 전달하며, 템플릿 외곽만 특수 토큰으로 파싱하고 본문은 literal 토큰화합니다.

대화는 자동 저장하지 않습니다. 앱 종료·업데이트·새 대화 전에 필요한 기록을 수동 저장합니다. 실제 사용자 대화·개인 용어사전과 원본 음성을 공개 fixture, 스크린샷, QA 자료에 옮기지 않습니다.

## 검사 명령

명령은 저장소 루트에서 실행합니다. 아래 검사들은 빌드 도구를 사용하지만 실제 마이크를 열거나 모델 가중치를 내려받지는 않습니다.

```sh
swift run --build-system native CaptionCoreChecks
swift run --build-system native TranslationSchedulingChecks
./scripts/check-app-model.sh
./scripts/check-lifecycle.sh
./scripts/check-audio-callbacks.sh
./scripts/check-system-audio.sh
./scripts/check-translation-leases.sh
./scripts/check-local-model-store.sh
./scripts/check-glossary-boundaries.sh
./scripts/check-prompt-safety.sh
```

| 검사 | 범위 |
|---|---|
| `CaptionCoreChecks` | 수정 버전, 회색→최종 조건, 늦은 결과 거부, 문맥 묶음과 내보내기 |
| `TranslationSchedulingChecks` | 최신 초안 유지, 확정 원문 우선 처리와 중복 방지 |
| `check-app-model.sh` | 주입한 번역기로 취소, 시간 초과, 재시도, 보완과 원문 보존 재현 |
| `check-lifecycle.sh` | 작업의 시간 제한과 취소 처리 |
| `check-audio-callbacks.sh` | 콜백 실행 영역, PCM 변환, 종료 시 입력 배출 |
| `check-system-audio.sh` | 합성 예문을 재생하는 프로세스 하나를 음소거로 탭해 제품 캡처·무음 채움·실제 영어 인식까지 확인. 준비된 영어 인식 자산이 필요하며, 전체 출력 탭과 권한 요청은 실행하지 않음 |
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

### 용어사전 품질과 실시간 비교

```sh
./scripts/check-dictionary-translation.sh
./scripts/check-dictionary-realtime.sh
./scripts/check-bidirectional-polish-pipeline.sh REPORT_JSON --dictionary-comparison
```

첫 검사는 사전 없음/분야 설명만/분야+용어의 실제 로컬 후보를 비교합니다. 두 번째는 같은 원문 이벤트를 실제 Apple 번역과 로컬 보완에 넣어, 보완 꺼짐/켜짐과 사전 없음/세 사전의 조합을 역순으로 반복합니다. 마지막은 한 번 만든 영어·한국어 합성 음성 파일을 실제 ASR와 제품 상태 경로에 실시간 속도로 공급하고 사전 없음/세 사전을 역순으로 반복합니다. 모두 설치된 고정 모델의 크기와 전체 SHA-256을 로드 전에 확인하며 다운로드하지 않습니다. 기록 파일은 [QA 안내](qa/README.md)에서 찾을 수 있습니다. 출력 guard·상태 검사 통과와 실제 사람의 음성 정확도, 화면 렌더 지연을 구분하세요.

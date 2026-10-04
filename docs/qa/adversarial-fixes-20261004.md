# P1 P2 결함 개선 검증

2026년 10월 4일 적대적 평가에서 재현한 P1 1개와 P2 7개를 모두 수정했습니다. 앱은 0.5.1 build 21로 빌드했으며, 수정 기능별 독립 소스에서 빌드와 관련 검사를 마친 뒤 각각 커밋하고 푸시했습니다.

[최초 평가](adversarial-evaluation-20261004.md)는 `9452aa2`의 실패 기록입니다. 이번 결과는 수정 코드 `822a42a`와 별도 원자료를 기준으로 합니다. 실행 환경은 Apple Silicon, macOS 26.7.1 build 25G241, Swift 6.4이며 최소 지원 대상은 macOS 26.4입니다.

## 결함별 변경과 재검증

| 우선순위 | 수정 | 확인 결과 |
|---|---|---|
| P1 시스템 오디오 시작 정지 | 장치 열거·생성·시작·조회·정리를 UI 밖 전용 큐로 이동. 전역 실행권을 하나로 제한 | 실제 시스템 오디오 검사 통과. 강제로 막힌 시작도 시간 제한·중지에 응답하고 늦은 자원을 정리 |
| P2 무음 시간 손실 | 경과 시간과 실제·합성 입력의 누적 프레임 차이만큼 무음 보충 | 원래 10초→5초 재현이 10초→10초, 160,000프레임으로 변경 |
| P2 제출 순서 경쟁 | 복사 전에 순번을 예약하고 완료한 복사를 순번대로 소비 | 원래 `[-1000, 1000]`이 `[1000, -1000]`으로 변경. 실제 입력·무음 혼합 시간도 보존 |
| P2 방향 전환 중 재개 | 전환 중 공개 시작·설정 변경·새 대화·재시도를 막고, 전환 소유자만 새 언어로 재개 | 보류한 설치 확인 중 `canStart=false`. 확인 후 한국어→영어로 전환, 이전 자막 보존 |
| P2 모델 검증 캐시 우회 | 캐시만으로 승인하지 않고 매 refresh 전체 SHA-256 검사. 열린 파일과 경로의 inode·device·mtime·ctime 확인 | 같은 크기·inode·mtime의 `abc→def` 변조를 거절하고 modelURL 미노출 |
| P2 Unicode 원문 증폭 | 용어·헤더의 문자·scalar·바이트 제한. 교정 크기를 할당 전에 계산 | 공격 사전 항목 제외, 원문 599바이트 유지. 전체 교정 초과 시 부분 교정 없이 원 ASR 유지·알림 |
| P2 NUL 프롬프트 절단 | 잘못된 사전 필드 무효화·알림. 길이를 전달하는 native ABI와 UTF-8/NUL 검증 | C 경계에서도 전체 원문 유지. native의 NUL·잘못된 UTF-8 요청 거절 |
| P2 모델 제어 토큰 입력 손실 | 템플릿 외곽만 특수 토큰 파싱, 본문은 literal 토큰화. 위험한 입력의 보완은 생략 | 1.8B·7B 본문 control token 0. 실제 앱에서는 원문과 빠른 baseline 유지, 다음 초안 진행 |

오디오 시작은 8초, 장치 조회는 3초, 하드웨어 중지 대기는 0.8초 한도로 반환합니다. HAL 자체를 강제로 중단하는 API를 추가한 것은 아닙니다. 응답하지 않는 실제 호출은 종료될 때까지 실행권을 유지하므로 새 하드웨어 작업이 쌓이지 않습니다. 앱 조작과 종료는 계속 응답합니다.

입력의 시간 기준도 장치 생성 후 pump가 사용하는 기준으로 통일했습니다. 시작이 실패하거나 취소되면 입력 시간이 공개되지 않으며, 장치 준비 대기를 녹음된 대화 시간으로 계산하지 않습니다.

모델 검증은 1MiB 단위로 백그라운드에서 수행하고, 겹친 refresh는 하나의 읽기를 공유합니다. 기존처럼 실제 모델 로딩과 첫 실행은 마이크 시작 전에 준비합니다.

## 보존한 동작

빠른 자막은 Apple의 설치된 로컬 엔진을 계속 사용합니다. 선택 모델은 확정 원문만 별도 한 작업 줄에서 보완합니다. 위험한 입력이나 지연·실패에서는 빠른 번역을 그대로 유지하며, 다음 초안 번역을 기다리게 하지 않습니다.

인식 원문을 앱이 만든 단어 치환으로 고치지 않았습니다. 개인 사전에 직접 적은 선택된 alias만 교정하며, 정상 한국어·영어·악센트·joined emoji와 비연쇄 교정을 검사했습니다. 무효 이름·문맥은 제외 이유를 표시하고, 사용자의 파일을 자동 수정하지 않습니다.

새 cloud 서비스나 sibling 엔진 의존성을 추가하지 않았습니다. 마이크 기본 선택, 사용자 선택 시스템 오디오, private tap, 원본 오디오 비저장 정책을 유지합니다.

## 검사 결과

| 검사 | 결과 |
|---|---|
| 앱 빌드·번들 서명·최소 OS | 0.5.1 build 21 통과, macOS 26.4 |
| CaptionCoreChecks | 40개 통과 |
| TranslationSchedulingChecks | 7개 통과 |
| AppModelChecks | 55개 통과 |
| AudioCallbackChecks | 18개 통과 |
| GlossaryBoundaryChecks | 9개 통과 |
| TranslationLeaseChecks·LifecycleChecks | 5개·3개 통과 |
| LocalModelStoreChecks | 기존 시나리오와 복원된 mtime/inode 변조 검사 통과 |
| PromptSafetyChecks | Swift 입력 경계 검사 통과 |
| 실제 native 입력 경계 | pinned 1.8B 14개·기존 실험 7B 14개 통과 |
| 기존 native ABI 검사 | 8개 통과 |
| ThreadSanitizer | 18개 오디오 검사에서 진단 없음 |
| 기존 무작위 상태·큐 재현 | 100개 seed, 100,000회 전이 통과 |
| 실제 시스템 오디오 | 단일 합성 재생 프로세스의 ASR·무음 확정·상태·탭 제거·시간 기준 검사 통과 |
| 연속 파일 입력 | 180초 입력·20초 재시작, final ASR 41개·provisional 이벤트 714개, 실패 없음 |
| 양방향 보완 파일 경로 | 4개 fixture의 상태·종료 조건 통과 |
| 화면 검사 | 65초 요청·70.788초 완료. 간략 창·사이드바·선택·읽던 위치 보존 |

마지막 실제 시스템 오디오 실행에서는 마지막 문장이 재생 종료 0.26초 뒤 capture가 계속 실행되는 동안 확정됐고, 종료 후 private tap이 제거됐습니다. 이 수치는 합성 fixture의 해당 실행 관찰이며 실제 화자의 자막 지연을 보장하지 않습니다.

막힌 장치 검사는 실제 `AudioCapture` 경로의 하드웨어 직전 gate를 사용했습니다. timeout·시작 중 stop·늦은 cleanup·500회 실행권 전달을 확인했으며, 해당 검사는 실제 마이크나 권한 창을 열지 않습니다.

원자료: [요약과 소스 SHA-256](raw/adversarial-fixes-20261004/summary.json), [검사 로그](raw/adversarial-fixes-20261004/checks.txt), [연속 입력](raw/adversarial-fixes-20261004/continuous.json), [양방향 파일](raw/adversarial-fixes-20261004/bidirectional.json), [UI](raw/adversarial-fixes-20261004/ui-soak-summary.json), [1.8B native](raw/adversarial-fixes-20261004/prompt-safety-small.json), [7B native](raw/adversarial-fixes-20261004/prompt-safety-dense.json), [ABI 회귀](raw/adversarial-fixes-20261004/runtime-regression.json).

## 실행과 커밋

추가 회귀 검사는 다음 명령으로 실행할 수 있습니다.

```sh
./scripts/check-glossary-boundaries.sh
./scripts/check-prompt-safety.sh
./scripts/check-app-model.sh
./scripts/check-audio-callbacks.sh
./scripts/check-system-audio.sh
./scripts/check-local-model-store.sh
```

실제 native 경계 도구는 [native_check.py](../../Tests/PromptSafetyChecks/native_check.py)이며, 호출할 때 모델 경로·템플릿·고정 크기·SHA-256을 명시해야 합니다. 모델을 다운로드하지 않고 로드 전에 전체 digest를 확인합니다. 7B 검사는 기존 실험 파일의 호환성 검사이며 앱에 7B 선택 기능을 추가하지 않았습니다.

| 커밋 | 변경 |
|---|---|
| `80abdd2` | 전체 모델 무결성 재검증 |
| `6c60581` | 방향 전환·재개 직렬화 |
| `38c7748` | 개인 사전 문자·교정 크기 제한 |
| `06c75cc` | 로컬 모델 제어 토큰·본문 격리 |
| `0facd55` | 오디오 하드웨어 격리·시간·순서 보존 |
| `822a42a` | 입력 시간 기준 정합·0.5.1 |

## 남은 검증 범위

이 수정으로 모델의 의미 정확성을 보장하지 않습니다. 최초 평가의 숫자 관계·요일 정정·조건 오역을 단어 치환으로 덮어쓰지 않았으며, 실제 원문 대조 평가가 계속 필요합니다. 형식·숫자 guard와 밝은 최종 상태는 의미 검증 표시가 아닙니다.

실제 화자의 마이크 정확도, 전체 출력 탭의 권한 거절·철회, macOS 26.4 실기기, 절전·장치 분리, 네트워크 차단, 새 30분 열화 검사는 이번에 하지 않았습니다. 비정상 SDK 시간값과 직접 Core API 호출의 P3 강화 후보도 이번 8개 수정과 구분해 남겼습니다.

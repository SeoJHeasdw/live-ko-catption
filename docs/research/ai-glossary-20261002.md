# AI 분야 용어 참고 조사 — 2026-10-02

## 범위와 적용 방식

IBM 및 Google의 공개 공식 문서에서 한국어 표기를 확인한 초기 후보 20개다. 공개 기술 용어만 포함하며 회사 내부 용어, 고객 이름, 고객별 표현은 포함하지 않는다. 아래 표기는 앱이 선택할 일관된 번역 표기이며, 유일한 정답이나 모든 문맥에 적용되는 강제 치환 규칙을 뜻하지 않는다.

선택한 AI 분야는 번역 모델에 짧은 분야 정보를 제공하고, 현재 원문에 등장하는 제한된 용어쌍만 참고하도록 한다. 원문이나 완성된 번역문을 내장 용어집으로 치환하지 않는다. 이 조사는 용어의 공개 표기와 모델의 공식 입력 방식을 확인한 것이며, 실제 마이크 품질·번역 자연스러움·지연 시간을 검증한 결과는 아니다.

## 초기 용어 후보

### 생성형 AI와 언어 처리

| 영어 표현 | 한국어 참고 표기 | 근거 |
|---|---|---|
| large language model | 대규모 언어 모델 | [IBM LLM 설명](https://www.ibm.com/kr-ko/think/topics/large-language-models) |
| generative AI | 생성형 AI | [IBM 생성형 AI 설명](https://www.ibm.com/kr-ko/think/topics/generative-ai) |
| foundation model | 파운데이션 모델 | [IBM 파운데이션 모델 안내](https://www.ibm.com/kr-ko/products/watsonx-ai/foundation-models) |
| natural language processing | 자연어 처리 | [IBM NLP 설명](https://www.ibm.com/kr-ko/think/topics/natural-language-processing) |
| AI agent | AI 에이전트 | [IBM AI 에이전트 설명](https://www.ibm.com/kr-ko/think/topics/ai-agents) |
| AI hallucination | AI 할루시네이션 | [IBM AI 할루시네이션 설명](https://www.ibm.com/kr-ko/think/topics/ai-hallucinations) |

`LLM`, `NLP`, `RAG` 같은 약어는 발화에 쓰인 약어를 자연스럽게 유지할 수 있다. 약어를 언제나 긴 한국어 풀네임으로 확장할 필요는 없다. 원문에 없는 약어·정의를 추가하지 않는다.

### 학습 방법

| 영어 표현 | 한국어 참고 표기 | 근거 |
|---|---|---|
| machine learning | 머신 러닝 | [IBM 머신 러닝 설명](https://www.ibm.com/kr-ko/think/topics/machine-learning) |
| deep learning | 딥 러닝 | [IBM 딥 러닝 설명](https://www.ibm.com/kr-ko/think/topics/deep-learning) |
| neural network | 신경망 | [IBM 신경망 설명](https://www.ibm.com/kr-ko/think/topics/neural-networks) |
| supervised learning | 지도 학습 | [IBM 머신 러닝 유형](https://www.ibm.com/kr-ko/think/topics/machine-learning-types) |
| unsupervised learning | 비지도 학습 | [IBM 머신 러닝 유형](https://www.ibm.com/kr-ko/think/topics/machine-learning-types) |
| reinforcement learning | 강화 학습 | [IBM 머신 러닝 유형](https://www.ibm.com/kr-ko/think/topics/machine-learning-types) |
| transfer learning | 전이 학습 | [IBM 미세 조정 설명](https://www.ibm.com/kr-ko/think/topics/fine-tuning) |
| fine-tuning | 미세 조정 | [IBM 미세 조정 설명](https://www.ibm.com/kr-ko/think/topics/fine-tuning) |

### 프롬프트·검색·모델 입력

| 영어 표현 | 한국어 참고 표기 | 근거 |
|---|---|---|
| prompt engineering | 프롬프트 엔지니어링 | [IBM 프롬프트 엔지니어링 설명](https://www.ibm.com/kr-ko/think/topics/prompt-engineering) |
| retrieval-augmented generation | 검색 증강 생성 | [IBM 한국어 RAG 설명](https://www.ibm.com/kr-ko/think/topics/retrieval-augmented-generation), [IBM 영어 RAG 설명](https://www.ibm.com/think/topics/retrieval-augmented-generation) |
| vector database | 벡터 데이터베이스 | [IBM 벡터 데이터베이스 설명](https://www.ibm.com/kr-ko/think/topics/vector-database) |
| vector embedding | 벡터 임베딩 | [IBM 벡터 임베딩 설명](https://www.ibm.com/kr-ko/think/topics/vector-embedding) |
| text embedding | 텍스트 임베딩 | [IBM 임베딩 아키텍처 안내](https://www.ibm.com/kr-ko/think/architectures/rag-cookbook/embedding) |
| context window | 컨텍스트 윈도우 | [Google 한국어 긴 컨텍스트 문서](https://ai.google.dev/gemini-api/docs/long-context?hl=ko) |

## 짧은 영어 분야 정보 후보

아래 문구는 이 앱을 위해 작성한 입력 후보다. 문서 인용이나 이전에 발화된 문장이 아니다. 화자의 문장 대신 번역되지 않도록 별도의 분야 정보로 전달하고, 실제로 등장한 AI 용어에만 적용한다.

```text
The discussion may concern AI models, machine learning, and generative AI. Use the AI meaning of technical terms only when supported by the source sentence. Preserve ordinary meanings, names, numbers, negation, and uncertainty.
```

IBM·금융권 등 다른 분야가 함께 선택되면 각 분야의 짧은 정보를 합칠 수 있다. 분야 선택만으로 모든 문장이 AI 이야기라고 단정하지 않는다.

## 문맥 없이 강제 적용하지 않을 표현

| 표현 | 구별할 의미 | 초기 처리 권고 |
|---|---|---|
| recall | 기억해 내기, 제품 리콜, 분류 지표 재현율 | 단독 고정 번역쌍에서 제외. 분류·탐지 문맥이 명시된 문장에만 지표 뜻을 참고. |
| precision | 일반적인 정확성·정밀함, 분류 지표 정밀도, 숫자 표현의 정밀도 | 단독 고정 번역쌍에서 제외. 문맥과 지표 정의를 보존. |
| token | 언어 모델 토큰, 인증 토큰, 보안 장치, 다른 종류의 표식 | 단독 고정 번역쌍에서 제외. AI 분야를 켜도 인증 관련 뜻을 덮어쓰지 않음. |
| inference / reasoning | 학습된 모델 실행과 논리적 추론이 한국어에서 모두 ‘추론’으로 표현될 수 있음 | 한국어→영어에서 ‘추론’을 항상 inference로 되돌리지 않음. 문장에 따라 선택. |
| model | AI 모델, 비즈니스 모델, 모형, 사람 | 단독 고정 번역쌍에서 제외. |
| agent | AI 시스템, 소프트웨어 구성 요소, 사람·조직의 대리인 | `AI agent`라는 긴 표현만 초기 용어로 포함. |
| hallucination | AI 출력 오류를 뜻하는 기술적 은유 또는 의학·일상 표현 | `AI hallucination`만 초기 용어로 포함. |
| embedding | AI 수치 표현 또는 일반적인 삽입·내장 동작 | `vector embedding`, `text embedding`만 초기 용어로 포함. |
| fine-tuning | AI 모델 조정 또는 일반적인 세부 조정 | AI 선택과 실제 문장 문맥을 함께 사용. |

단복수나 `fine tuning` / `fine-tuning`, `retrieval augmented generation` / `retrieval-augmented generation` 같은 표기 변형은 같은 전문 표현의 매칭 후보다. 매칭이 된다는 이유로 원문을 고쳐 쓰지는 않는다. 서로 다른 사전이 같은 용어에 다른 표기를 제시하면 조용히 둘 다 지시하지 않고 하나의 우선순위를 적용하거나 충돌을 알린다.

## Hy-MT2 공식 입력 방식

[Tencent의 Hy-MT2 공식 README](https://github.com/Tencent-Hunyuan/Hy-MT2/blob/main/README.md#hy-mt2-translation-task-instruction-examples-chinese-english-comparison)는 용어 참고, 문체 지정, 배경 정보 입력을 서로 다른 번역 지시 예제로 제공한다. 용어 입력은 원문/번역 용어쌍을 먼저 제시하고 번역할 원문을 뒤에 놓는 형식이다. 배경 정보는 번역할 원문과 구분하며, 언어는 `Korean`, `English`처럼 전체 언어 이름으로 쓰라고 안내한다.

따라서 분야 정보와 용어쌍을 별도 입력으로 다루는 것은 공식 지원 방식에 근거한다. 다만 용어 준수나 자연스러움 개선을 보장하는 것은 아니다. 현재 앱의 빠른 Apple 번역은 이 프롬프트를 받지 않으며, 선택적 로컬 모델이 확정된 원문을 다듬을 때 적용된다. 분야 정보 추가 후에는 원문 대신 분야 설명을 번역하는지, 기술 뜻을 일상 문장에 잘못 적용하는지, 숫자·부정·조건을 바꾸는지를 실제 후보 출력으로 확인해야 한다.

## 구현에 옮길 수 있는 용어쌍

방향에 따라 입력/출력 언어를 바꾸되, 모호한 단어를 역방향 고정 치환으로 만들지 않는다. 아래 JSON은 조사 결과를 옮기기 위한 데이터 예시이며 앱 파일 형식을 확정하는 스키마는 아니다.

```json
[
  {"english":"large language model","korean":"대규모 언어 모델"},
  {"english":"generative AI","korean":"생성형 AI"},
  {"english":"foundation model","korean":"파운데이션 모델"},
  {"english":"natural language processing","korean":"자연어 처리"},
  {"english":"AI agent","korean":"AI 에이전트"},
  {"english":"AI hallucination","korean":"AI 할루시네이션"},
  {"english":"machine learning","korean":"머신 러닝"},
  {"english":"deep learning","korean":"딥 러닝"},
  {"english":"neural network","korean":"신경망"},
  {"english":"supervised learning","korean":"지도 학습"},
  {"english":"unsupervised learning","korean":"비지도 학습"},
  {"english":"reinforcement learning","korean":"강화 학습"},
  {"english":"transfer learning","korean":"전이 학습"},
  {"english":"fine-tuning","korean":"미세 조정"},
  {"english":"prompt engineering","korean":"프롬프트 엔지니어링"},
  {"english":"retrieval-augmented generation","korean":"검색 증강 생성"},
  {"english":"vector database","korean":"벡터 데이터베이스"},
  {"english":"vector embedding","korean":"벡터 임베딩"},
  {"english":"text embedding","korean":"텍스트 임베딩"},
  {"english":"context window","korean":"컨텍스트 윈도우"}
]
```

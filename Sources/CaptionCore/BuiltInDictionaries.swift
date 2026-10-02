import Foundation

/// Reviewed public terminology. Provenance is recorded in docs/research.
/// These entries are model references, never substitutions in source/output.
public enum BuiltInDictionaries {
    public static let aiID = "builtin:ai"
    public static let ibmID = "builtin:ibm"
    public static let financeID = "builtin:finance"

    public static let ai = CaptionDictionary(id: aiID, name: "AI",
        context: "AI, machine learning and generative AI terminology.",
        glossary: CaptionGlossary(text: """
        large language model = 대규모 언어 모델
        generative AI = 생성형 AI
        foundation model = 파운데이션 모델
        natural language processing = 자연어 처리
        AI agent = AI 에이전트
        AI hallucination = AI 할루시네이션
        machine learning = 머신 러닝
        deep learning = 딥 러닝
        neural network = 신경망
        supervised learning = 지도 학습
        unsupervised learning = 비지도 학습
        reinforcement learning = 강화 학습
        transfer learning = 전이 학습
        fine-tuning = 미세 조정
        prompt engineering = 프롬프트 엔지니어링
        retrieval-augmented generation = 검색 증강 생성
        vector database = 벡터 데이터베이스
        vector embedding = 벡터 임베딩
        text embedding = 텍스트 임베딩
        context window = 컨텍스트 윈도우
        """))
    public static let ibm = CaptionDictionary(id: ibmID, name: "IBM",
        context: "IBM enterprise software, hybrid cloud and infrastructure; keep official IBM product names.",
        glossary: CaptionGlossary(text: """
        watsonx.ai = watsonx.ai
        watsonx.data = watsonx.data
        watsonx.governance = watsonx.governance
        watsonx Orchestrate = watsonx Orchestrate
        watsonx Code Assistant for Z = watsonx Code Assistant for Z
        IBM Granite = IBM Granite
        IBM Cloud = IBM Cloud
        IBM Z = IBM Z
        IBM Power = IBM Power
        Db2 = Db2
        IBM MQ = IBM MQ
        Instana = Instana
        Turbonomic = Turbonomic
        IBM Concert = IBM Concert
        IBM Maximo = IBM Maximo
        Cognos Analytics = Cognos Analytics
        Planning Analytics = Planning Analytics
        SPSS Statistics = SPSS Statistics
        Cloud Pak for Integration = Cloud Pak for Integration
        Cloud Pak for Business Automation = Cloud Pak for Business Automation
        """))
    public static let finance = CaptionDictionary(id: financeID, name: "금융권",
        context: "Banking and financial services: payments, risk management and regulatory compliance.",
        glossary: CaptionGlossary(text: """
        anti-money laundering = 자금세탁방지
        know your customer = 고객확인
        customer due diligence = 고객확인제도
        enhanced due diligence = 강화된 고객확인
        transaction monitoring = 거래 모니터링
        fraud detection = 사기 탐지
        customer onboarding = 고객 온보딩
        audit trail = 감사 추적
        loan processing = 대출 처리
        regulatory compliance = 규정 준수
        retail banking = 소매 금융
        core banking system = 코어 뱅킹 시스템
        open banking = 오픈 뱅킹
        embedded finance = 임베디드 금융
        payment processing = 결제 처리
        credit risk = 신용위험
        liquidity risk = 유동성리스크
        operational risk = 운영리스크
        interest rate swap = 금리스왑
        liquidity coverage ratio = 유동성커버리지비율
        net stable funding ratio = 순안정자금조달비율
        business continuity plan = 업무지속계획
        """))
    public static let all = [ai, ibm, finance]

    /// Retains reproducible inputs for old QA fixtures, outside the app's UI.
    public static func legacy(_ domain: TranslationDomain, glossary: [GlossaryEntry] = []) -> [CaptionDictionary] {
        guard domain != .general else { return [] }
        let it = CaptionDictionary(id: "legacy:it", name: "IT",
            context: domain == .it ? "This is an IT discussion." : "",
            glossary: CaptionGlossary(text: """
            deployment = 배포
            rollback = 롤백
            latency = 지연 시간
            throughput = 처리량
            memory leak = 메모리 누수
            authentication = 인증
            authorization = 권한 부여
            load balancer = 로드 밸런서
            container = 컨테이너
            namespace = 네임스페이스
            cache = 캐시
            API = API
            Kubernetes = Kubernetes
            precision = 정밀도
            recall = 재현율
            """))
        if domain == .it { return [it] }
        return [CaptionDictionary(id: CaptionDictionary.legacyPersonalID, name: "개인 용어",
                    glossary: CaptionGlossary(entries: glossary), isPersonal: true), it]
    }
}

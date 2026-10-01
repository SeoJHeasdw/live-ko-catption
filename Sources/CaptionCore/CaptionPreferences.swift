import Foundation

/// One input language is active at a time. The user chooses it before a
/// conversation and may switch it between runs of that conversation; it is
/// never inferred from individual speech fragments.
public enum CaptionDirection: String, CaseIterable, Hashable, Sendable {
    case englishToKorean
    case koreanToEnglish

    public var sourceLanguageCode: String { self == .englishToKorean ? "en" : "ko" }
    public var targetLanguageCode: String { self == .englishToKorean ? "ko" : "en" }
    public var speechLocaleIdentifier: String { self == .englishToKorean ? "en-US" : "ko-KR" }
    public var sourceDisplayName: String { self == .englishToKorean ? "영어" : "한국어" }
    public var targetDisplayName: String { self == .englishToKorean ? "한국어" : "영어" }
    public var label: String { "\(sourceDisplayName) → \(targetDisplayName)" }
    public var sourceExportLabel: String { sourceLanguageCode.uppercased() }
    public var targetExportLabel: String { targetLanguageCode.uppercased() }

    public static let preferenceKey = "captionDirection"
}

public enum TranslationDomain: String, CaseIterable, Hashable, Sendable {
    case general
    case it

    public var label: String { self == .general ? "일반" : "IT" }
    public static let preferenceKey = "translationDomain"
}

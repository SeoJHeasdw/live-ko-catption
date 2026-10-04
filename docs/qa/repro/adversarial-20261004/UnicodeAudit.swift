import Foundation
@main struct UnicodeAmplification {
 static func main() {
  let canonical = "A" + String(repeating: "\u{0301}", count: 10_000)
  let file = canonical + " = 단어 | heard\n"
  let glossary = CaptionGlossary(text: file)
  let source = Array(repeating: "heard", count: 100).joined(separator: " ")
  let began = ProcessInfo.processInfo.systemUptime
  let corrected = glossary.correcting(source, direction: .englishToKorean)
  let ended = ProcessInfo.processInfo.systemUptime
  print("fileBytes=\(file.utf8.count), entryCount=\(glossary.entries.count), termGraphemes=\(canonical.count), termScalars=\(canonical.unicodeScalars.count), originalBytes=\(source.utf8.count), correctedBytes=\(corrected.utf8.count), correctedGraphemes=\(corrected.count), duration_s=\(ended-began)")
  print("local request budget accepted=\(LocalTranslationRequest(source: corrected, direction: .englishToKorean).isWithinBudget)")
 }
}

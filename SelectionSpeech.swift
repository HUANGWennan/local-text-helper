import AppKit
import AVFoundation

final class SelectionSpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var remaining = 0
    var finished: (() -> Void)?
    var isSpeaking: Bool { remaining > 0 }
    override init() { super.init(); synthesizer.delegate = self }
    func stop() {
        remaining = 0; synthesizer.stopSpeaking(at: .immediate); finished?()
    }
    func start(_ text: String) {
        stop()
        // Keep English words together and switch voices for Chinese runs.
        var parts: [(String, String)] = []
        var buffer = "", language = "en-US"
        for character in text {
            let han = character.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x2FFFF).contains($0.value) }
            let latin = character.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.isASCII }
            let next = han ? "zh-CN" : (latin ? "en-US" : language)
            if next != language && !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append((buffer, language)); buffer = ""
            }
            language = next; buffer.append(character)
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append((buffer, language)) }
        let installed = AVSpeechSynthesisVoice.speechVoices()
        remaining = parts.count
        for (content, language) in parts {
            let utterance = AVSpeechUtterance(string: content)
            utterance.voice = installed.first { $0.language == language }
                ?? installed.first { $0.language.hasPrefix(String(language.prefix(2))) }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
            synthesizer.speak(utterance)
        }
        if remaining == 0 { finished?() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        remaining = max(0, remaining - 1)
        if remaining == 0 { finished?() }
    }
}

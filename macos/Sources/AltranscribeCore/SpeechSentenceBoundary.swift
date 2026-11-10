import Foundation
import NaturalLanguage

/// Token decoding can stall while speech continues. Only actual quiet audio can confirm a pause.
struct SpeechPauseDetector {
    private var noise: Float = 0.0001
    private(set) var duration = 0.0
    mutating func accept(_ samples: ArraySlice<Float>) {
        for start in stride(from: samples.startIndex, to: samples.endIndex, by: 320) {
            let end = min(samples.endIndex, start + 320)
            let rms = sqrt(samples[start..<end].reduce(Float.zero) { $0 + $1 * $1 } / Float(end - start))
            noise += (rms < noise ? 0.1 : 0.002) * (rms - noise)
            duration = rms < max(0.0002, noise * 1.8) ? duration + Double(end - start) / 16_000 : 0
        }
    }
}

/// Display hypotheses immediately; commit at a sentence or a meaningful pause, not a transport interval.
enum SpeechSentenceBoundary {
    static func cut(tokens: ArraySlice<String>, times: ArraySlice<Double>, quiet: Double, closing: Bool) -> Int? {
        guard let first = times.first, let last = times.last, !tokens.isEmpty else { return nil }
        let text = tokens.joined()
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentenceEnd: Int?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isComplete(sentence) else { return true }
            let trimmed = text[..<range.upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let length = trimmed.count + text.prefix(while: \.isWhitespace).count
            var count = 0
            for index in tokens.indices {
                count += tokens[index].count
                if count >= length {
                    if index + 1 < tokens.endIndex || quiet >= 0.45 || closing { sentenceEnd = index + 1 }
                    break
                }
            }
            return sentenceEnd == nil
        }
        if let sentenceEnd { return sentenceEnd }
        if closing { return tokens.endIndex }
        let words = text.split(whereSeparator: \.isWhitespace).count
        // A pause after “to”, “the”, or a tiny fragment is often hesitation inside the same thought.
        let pause = words < 5 || isContinuation(text) ? 2.6 : 1.25
        if quiet >= pause { return tokens.endIndex }
        // Unpunctuated continuous speech still needs bounded captions and translation requests.
        // Retain the last word as a hypothesis; never split a subword token across rows.
        if last - first >= 18 {
            let words = NLTokenizer(unit: .word)
            words.string = text
            var lastWordStart = 0
            words.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                lastWordStart = text[..<range.lowerBound].utf8.count
                return true
            }
            var bytes = 0
            for index in tokens.indices {
                bytes += tokens[index].utf8.count
                if bytes > lastWordStart { return index > tokens.startIndex ? index : nil }
            }
        }
        return nil
    }

    static func isComplete(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last, ".!?。！？".contains(last) else { return false }
        let word = text.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
        return !["mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e.", "vs.", "u.s."].contains(word)
    }

    static func continuesWord(_ previous: String, token: String) -> Bool {
        guard !token.isEmpty, token.first?.isWhitespace != true else { return false }
        let tail = String(previous.suffix(64))
        let text = tail + token
        let boundary = text.utf8.index(text.utf8.startIndex, offsetBy: tail.utf8.count)
        let words = NLTokenizer(unit: .word)
        words.string = text
        var continues = false
        words.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            continues = range.lowerBound < boundary && range.upperBound > boundary
            return !continues && range.lowerBound < boundary
        }
        return continues
    }

    static func isContinuation(_ text: String) -> Bool {
        let word = text.split(whereSeparator: \.isWhitespace).last?.lowercased()
            .trimmingCharacters(in: .punctuationCharacters) ?? ""
        return ["a", "an", "the", "to", "of", "for", "with", "and", "or", "but", "that", "which", "because", "if", "when", "it's", "its"].contains(word)
    }

    static func shouldMerge(_ previous: TranscriptSegment, nextStart: Double) -> Bool {
        let gap = nextStart - previous.end
        let unfinished = !isComplete(previous.text) || (previous.text.last == "." && isContinuation(previous.text))
        // Word count does not tell us whether a thought has ended. Keep an unfinished
        // clause with its continuation, while preserving real pauses and bounded windows.
        return unfinished && gap >= -0.35 && gap <= 2.0 &&
            nextStart - previous.start < 12
    }
}

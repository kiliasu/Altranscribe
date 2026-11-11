import Foundation

/// Engine result IDs describe recognition updates, not necessarily complete sentences.
/// Keep each source's latest revision so a late correction can rebuild its joined sentence.
public struct LiveSentenceAssembler {
    private var groups: [UUID: [TranscriptSegment]] = [:]
    private var locations: [UUID: (UUID, Int)] = [:]
    private var last: UUID?
    private var pending: UUID?
    public init() {}

    public mutating func update(_ finalized: [TranscriptSegment], partial: TranscriptSegment?)
        -> (finalized: [TranscriptSegment], partial: TranscriptSegment?) {
        var changed: [UUID] = []
        for part in finalized + (partial.map { [$0] } ?? []) {
            let id: UUID
            if let (group, index) = locations[part.id] {
                groups[group]![index] = part; id = group
            } else if let last, let previous = sentence(last), !previous.text.isEmpty, !part.text.isEmpty,
                      SpeechSentenceBoundary.shouldMerge(previous, nextStart: part.start), part.end - previous.start <= 18 {
                locations[part.id] = (last, groups[last]!.count)
                groups[last]!.append(part); id = last
            } else {
                groups[part.id] = [part]; locations[part.id] = (part.id, 0); id = part.id
                if last.flatMap({ sentence($0)?.start }).map({ part.start >= $0 }) ?? true { last = id }
            }
            if !changed.contains(id) { changed.append(id) }
            if finalized.contains(where: { $0.id == pending }) { pending = nil }
        }
        if let partial { pending = partial.id }
        let pendingGroup = pending.flatMap { locations[$0]?.0 }
        return (changed.filter { $0 != pendingGroup }.compactMap(sentence), pendingGroup.flatMap(sentence))
    }

    private func sentence(_ id: UUID) -> TranscriptSegment? {
        guard let parts = groups[id], var line = parts.first else { return nil }
        line.id = id
        line.text = joined(parts.map(\.text))
        line.end = parts.map(\.end).max() ?? line.end
        let translations = parts.compactMap(\.translation)
        line.translation = translations.isEmpty ? nil : joined(translations)
        line.estimated = parts.contains(where: \.estimated)
        return line
    }

    private func joined(_ values: [String]) -> String {
        values.filter { !$0.isEmpty }.reduce("") { previous, next in
            guard !previous.isEmpty else { return next }
            var previous = previous
            // Batch recognizers sometimes add a period to an unfinished chunk ending in “of” or “the”.
            if previous.last == ".", SpeechSentenceBoundary.isContinuation(previous) { previous.removeLast() }
            let punctuation = next.first.map { ".,!?;:。，！？；：".contains($0) } ?? false
            let cjk = [previous.last, next.first].allSatisfy {
                guard let value = $0?.unicodeScalars.first?.value else { return false }
                return (0x2E80...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value) || (0x20000...0x2FA1F).contains(value)
            }
            return previous + (punctuation || cjk ? "" : " ") + next
        }
    }
}

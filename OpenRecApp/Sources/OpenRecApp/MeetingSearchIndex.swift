import Foundation
import SwiftUI

/// Full-text index for the Meetings library.
///
/// Terms are case- and diacritic-insensitive. A query matches a meeting only
/// when every word matches. Every word except the last must match a whole
/// term; the last word also matches terms that start with it. A meeting whose
/// title satisfies the whole query ranks above a body-only match, and a newer
/// meeting ranks first within that tier.
struct MeetingSearchSnippet: Equatable {
    struct Segment: Equatable {
        var text: String
        var isMatch: Bool
    }

    var segments: [Segment]

    var text: String { segments.map(\.text).joined() }
}

struct MeetingSearchHit: Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    /// The title alone satisfies the query, so this hit outranks body matches.
    var matchesTitle: Bool
    var snippet: MeetingSearchSnippet
    /// The snippet is the full displayed title, so the row can highlight that
    /// title instead of repeating it under the meeting name.
    var snippetReplacesTitle: Bool
}

enum MeetingSearchTokenizer {
    struct Token: Equatable {
        var term: String
        /// Range of the original word, including an interior apostrophe.
        var range: Range<String.Index>
    }

    static let locale = Locale(identifier: "en_US_POSIX")

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isWordCore(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var term = ""
            while index < text.endIndex {
                let character = text[index]
                if isWordCore(character) {
                    term.append(contentsOf: fold(character))
                    index = text.index(after: index)
                    continue
                }
                let next = text.index(after: index)
                if isApostrophe(character), next < text.endIndex, isWordCore(text[next]) {
                    index = next
                    continue
                }
                break
            }
            if !term.isEmpty {
                tokens.append(Token(term: term, range: start..<index))
            }
        }
        return tokens
    }

    static func fold(_ character: Character) -> String {
        String(character)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private static func isWordCore(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}

/// Inverted index over the meetings already loaded in the library.
/// Call `upsert` when a meeting is saved or edited, `remove` when it is
/// deleted, and `replaceAll` when the library is reloaded.
final class MeetingSearchIndex {
    private struct IndexedField {
        enum Kind {
            case primaryTitle
            case titleAlias
            case body
        }

        var text: String
        var kind: Kind

        var isTitle: Bool { kind == .primaryTitle || kind == .titleAlias }
    }

    private struct Entry {
        var startedAt: Date
        var fields: [IndexedField]
        var titleTerms: Set<String>
        var signature: Int
    }

    private var entries: [UUID: Entry] = [:]
    private var docTerms: [UUID: Set<String>] = [:]
    private var termToDocs: [String: Set<UUID>] = [:]
    private var sortedTerms: [String] = []
    private var termsDirty = false

    private static let snippetLeading = 48
    private static let snippetTrailing = 72
    private static let fullTitleLimit = 160

    func search(query: String) -> [MeetingSearchHit] {
        let queryTokens = MeetingSearchTokenizer.tokens(in: query).map(\.term)
        guard let last = queryTokens.last else { return [] }

        var candidates: Set<UUID>?
        for term in queryTokens.dropLast() {
            let docs = termToDocs[term] ?? []
            if let existing = candidates {
                candidates = existing.intersection(docs)
            } else {
                candidates = docs
            }
            if candidates?.isEmpty == true { return [] }
        }

        let prefixed = documentIDs(withPrefix: last)
        let matched: Set<UUID>
        if let existing = candidates {
            matched = existing.intersection(prefixed)
        } else {
            matched = prefixed
        }

        let hits = matched.compactMap { id -> MeetingSearchHit? in
            guard let entry = entries[id] else { return nil }
            return makeHit(id: id, entry: entry, queryTokens: queryTokens)
        }
        return hits.sorted { lhs, rhs in
            if lhs.matchesTitle != rhs.matchesTitle {
                return lhs.matchesTitle && !rhs.matchesTitle
            }
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func upsert(_ meeting: MeetingRecord) {
        let built = Self.makeEntry(for: meeting)
        if entries[meeting.id]?.signature == built.entry.signature { return }
        if entries[meeting.id] != nil {
            remove(id: meeting.id)
        }
        entries[meeting.id] = built.entry
        docTerms[meeting.id] = built.terms
        for term in built.terms {
            termToDocs[term, default: []].insert(meeting.id)
        }
        termsDirty = true
    }

    func remove(id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        let terms = docTerms.removeValue(forKey: id) ?? []
        for term in terms {
            guard var docs = termToDocs[term] else { continue }
            docs.remove(id)
            if docs.isEmpty {
                termToDocs.removeValue(forKey: term)
            } else {
                termToDocs[term] = docs
            }
        }
        termsDirty = true
    }

    func replaceAll(_ meetings: [MeetingRecord]) {
        var seen = Set<UUID>()
        seen.reserveCapacity(meetings.count)
        for meeting in meetings {
            seen.insert(meeting.id)
            upsert(meeting)
        }
        let stale = entries.keys.filter { !seen.contains($0) }
        for id in stale {
            remove(id: id)
        }
    }

    private func makeHit(id: UUID, entry: Entry, queryTokens: [String]) -> MeetingSearchHit {
        let built = Self.snippet(for: entry, queryTokens: queryTokens)
        return MeetingSearchHit(
            id: id,
            startedAt: entry.startedAt,
            matchesTitle: Self.matchesTitle(entry, queryTokens: queryTokens),
            snippet: built.snippet,
            snippetReplacesTitle: built.replacesTitle
        )
    }

    private func documentIDs(withPrefix prefix: String) -> Set<UUID> {
        var ids = Set<UUID>()
        for term in terms(withPrefix: prefix) {
            if let docs = termToDocs[term] {
                ids.formUnion(docs)
            }
        }
        return ids
    }

    private func terms(withPrefix prefix: String) -> ArraySlice<String> {
        guard !prefix.isEmpty else { return [] }
        ensureSortedTerms()
        var lower = 0
        var upper = sortedTerms.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if sortedTerms[mid] < prefix {
                lower = mid + 1
            } else {
                upper = mid
            }
        }
        var end = lower
        while end < sortedTerms.count, sortedTerms[end].hasPrefix(prefix) {
            end += 1
        }
        return sortedTerms[lower..<end]
    }

    private func ensureSortedTerms() {
        guard termsDirty else { return }
        sortedTerms = termToDocs.keys.sorted()
        termsDirty = false
    }

    private static func matchesTitle(_ entry: Entry, queryTokens: [String]) -> Bool {
        guard let last = queryTokens.last else { return false }
        for term in queryTokens.dropLast() where !entry.titleTerms.contains(term) {
            return false
        }
        return entry.titleTerms.contains { $0.hasPrefix(last) }
    }

    private static func termMatches(_ term: String, queryTokens: [String]) -> Bool {
        guard let last = queryTokens.last else { return false }
        if queryTokens.dropLast().contains(term) { return true }
        return term.hasPrefix(last)
    }

    private static func snippet(
        for entry: Entry,
        queryTokens: [String]
    ) -> (snippet: MeetingSearchSnippet, replacesTitle: Bool) {
        for field in entry.fields {
            let tokens = MeetingSearchTokenizer.tokens(in: field.text)
            guard let match = tokens.first(where: { termMatches($0.term, queryTokens: queryTokens) }) else {
                continue
            }
            if field.kind == .primaryTitle, field.text.count <= fullTitleLimit {
                let snippet = highlighted(field.text, tokens: tokens, queryTokens: queryTokens)
                return (snippet, !snippet.text.isEmpty)
            }
            return (windowed(field.text, tokens: tokens, around: match, queryTokens: queryTokens), false)
        }
        return (MeetingSearchSnippet(segments: []), false)
    }

    private static func highlighted(
        _ text: String,
        tokens: [MeetingSearchTokenizer.Token],
        queryTokens: [String]
    ) -> MeetingSearchSnippet {
        var segments: [MeetingSearchSnippet.Segment] = []
        var cursor = text.startIndex
        for token in tokens where termMatches(token.term, queryTokens: queryTokens) {
            if cursor < token.range.lowerBound {
                segments.append(segment(text[cursor..<token.range.lowerBound], isMatch: false))
            }
            segments.append(segment(text[token.range], isMatch: true))
            cursor = token.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(segment(text[cursor..<text.endIndex], isMatch: false))
        }
        return MeetingSearchSnippet(segments: segments.filter { !$0.text.isEmpty })
    }

    private static func windowed(
        _ text: String,
        tokens: [MeetingSearchTokenizer.Token],
        around match: MeetingSearchTokenizer.Token,
        queryTokens: [String]
    ) -> MeetingSearchSnippet {
        let start = snippetStart(in: text, matchStart: match.range.lowerBound)
        let end = snippetEnd(in: text, matchEnd: match.range.upperBound)
        var segments: [MeetingSearchSnippet.Segment] = []
        if start > text.startIndex {
            segments.append(MeetingSearchSnippet.Segment(text: "…", isMatch: false))
        }
        var cursor = start
        for token in tokens where token.range.lowerBound < end
            && start < token.range.upperBound
            && termMatches(token.term, queryTokens: queryTokens) {
            let tokenStart = token.range.lowerBound < start ? start : token.range.lowerBound
            let tokenEnd = token.range.upperBound > end ? end : token.range.upperBound
            if cursor < tokenStart {
                segments.append(segment(text[cursor..<tokenStart], isMatch: false))
            }
            if tokenStart < tokenEnd {
                segments.append(segment(text[tokenStart..<tokenEnd], isMatch: true))
            }
            cursor = tokenEnd
        }
        if cursor < end {
            segments.append(segment(text[cursor..<end], isMatch: false))
        }
        if end < text.endIndex {
            segments.append(MeetingSearchSnippet.Segment(text: "…", isMatch: false))
        }
        return MeetingSearchSnippet(segments: segments.filter { !$0.text.isEmpty })
    }

    private static func segment(_ substring: Substring, isMatch: Bool) -> MeetingSearchSnippet.Segment {
        MeetingSearchSnippet.Segment(text: flatten(String(substring)), isMatch: isMatch)
    }

    private static func flatten(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func snippetStart(in text: String, matchStart: String.Index) -> String.Index {
        let desired = text.index(matchStart, offsetBy: -snippetLeading, limitedBy: text.startIndex) ?? text.startIndex
        var index = desired
        if index > text.startIndex {
            let previous = text.index(before: index)
            if !text[previous].isWhitespace {
                while index < matchStart, !text[index].isWhitespace {
                    index = text.index(after: index)
                }
            }
        }
        while index < matchStart, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    private static func snippetEnd(in text: String, matchEnd: String.Index) -> String.Index {
        let desired = text.index(matchEnd, offsetBy: snippetTrailing, limitedBy: text.endIndex) ?? text.endIndex
        guard desired < text.endIndex, desired > text.startIndex else { return desired }
        let previous = text.index(before: desired)
        guard !text[previous].isWhitespace, !text[desired].isWhitespace else { return desired }
        var index = desired
        while index < text.endIndex, !text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    private static func makeEntry(for meeting: MeetingRecord) -> (entry: Entry, terms: Set<String>) {
        let fields = fields(for: meeting)
        var terms = Set<String>()
        var titleTerms = Set<String>()
        for field in fields {
            for token in MeetingSearchTokenizer.tokens(in: field.text) {
                terms.insert(token.term)
                if field.isTitle { titleTerms.insert(token.term) }
            }
        }
        let entry = Entry(
            startedAt: meeting.startedAt,
            fields: fields,
            titleTerms: titleTerms,
            signature: signature(startedAt: meeting.startedAt, fields: fields)
        )
        return (entry, terms)
    }

    private static func fields(for meeting: MeetingRecord) -> [IndexedField] {
        var fields: [IndexedField] = []
        let primary = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            fields.append(IndexedField(text: primary, kind: .primaryTitle))
        }
        appendAlias(meeting.callTitle, to: &fields)
        appendAlias(meeting.insights.title, to: &fields)
        appendBody(meeting.insights.summary, to: &fields)
        appendBody(meeting.insights.aiNotes, to: &fields)
        appendBody(meeting.insights.decisions.joined(separator: "\n"), to: &fields)
        appendBody(nextSteps(for: meeting), to: &fields)
        let transcript = SpeakerNames.apply(meeting.speakerNames ?? [:], to: meeting.transcript ?? "")
        appendBody(transcript, to: &fields)
        appendBody(meeting.insights.participants.joined(separator: "\n"), to: &fields)
        appendBody(speakerNames(for: meeting), to: &fields)
        return fields
    }

    private static func appendAlias(_ raw: String?, to fields: inout [IndexedField]) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        guard trimmed.caseInsensitiveCompare("Untitled call") != .orderedSame else { return }
        guard !fields.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        fields.append(IndexedField(text: trimmed, kind: .titleAlias))
    }

    private static func appendBody(_ raw: String, to fields: inout [IndexedField]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fields.append(IndexedField(text: trimmed, kind: .body))
    }

    private static func nextSteps(for meeting: MeetingRecord) -> String {
        meeting.insights.actionItems.compactMap { item -> String? in
            let parts = [item.owner, item.task, item.dueDate ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private static func speakerNames(for meeting: MeetingRecord) -> String {
        let mapping = meeting.speakerNames ?? [:]
        let identified = SpeakerNames.identifiedNames(transcript: meeting.transcript ?? "", mapping: mapping)
        var names: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: MeetingSearchTokenizer.locale)
                .lowercased(with: MeetingSearchTokenizer.locale)
            guard seen.insert(key).inserted else { return }
            names.append(trimmed)
        }
        for name in identified { append(name) }
        for name in mapping.values { append(name) }
        return names.joined(separator: "\n")
    }

    private static func signature(startedAt: Date, fields: [IndexedField]) -> Int {
        var hasher = Hasher()
        hasher.combine(startedAt.timeIntervalSinceReferenceDate)
        for field in fields {
            switch field.kind {
            case .primaryTitle:
                hasher.combine(0)
            case .titleAlias:
                hasher.combine(1)
            case .body:
                hasher.combine(2)
            }
            hasher.combine(field.text)
        }
        return hasher.finalize()
    }
}

struct MeetingSearchSnippetText: View {
    let snippet: MeetingSearchSnippet
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    var color: Color
    var matchColor: Color
    var lineLimit: Int = 2

    var body: some View {
        Text(attributed)
            .lineLimit(lineLimit)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in snippet.segments {
            var piece = AttributedString(segment.text)
            piece.font = .system(size: size, weight: segment.isMatch ? .semibold : weight)
            piece.foregroundColor = segment.isMatch ? matchColor : color
            result.append(piece)
        }
        return result
    }
}

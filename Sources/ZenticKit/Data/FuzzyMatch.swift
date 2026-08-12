import Foundation

/// Subsequence scoring for the ⌘K palette.
///
/// The palette ranks three unrelated sources — open tabs, history, actions —
/// against one query, so the scorer has to be a pure function of `(query,
/// candidate)` with a comparable result. Hence a value type in the data layer
/// rather than something wired into the view.
///
/// Deliberately not a full Smith-Waterman: the candidate strings are titles and
/// URLs of at most a couple of hundred characters, and the greedy pass with
/// boundary bonuses produces the ordering people expect ("gh" finds
/// "github.com", "dt" finds "Design Tokens") for a fraction of the code.
public struct FuzzyMatch: Sendable, Hashable {
    public var score: Int
    /// Character offsets in the candidate that the query matched, ascending. The
    /// palette bolds these.
    public var matched: [Int]

    public init(score: Int, matched: [Int]) {
        self.score = score
        self.matched = matched
    }
}

public enum FuzzyMatcher {
    /// Consecutive matches are what make an acronym-ish query beat a scattered one.
    private static let adjacencyBonus = 15
    /// A match at the start of a word — after a separator, or at a camel-case hump.
    private static let boundaryBonus = 12
    /// A match at offset zero. Ranks `google.com` above `pages.google.com` for "g".
    private static let prefixBonus = 20
    /// Charged per skipped candidate character, so shorter candidates win ties.
    private static let gapPenalty = 1
    /// Cap on the gap penalty, so a match late in a long URL is not disqualified.
    private static let maxGapPenalty = 30

    /// - Returns: nil when `query` is not a case-insensitive subsequence of
    ///   `candidate`. An empty query matches everything with score 0, which is what
    ///   makes the palette show a plain recency list before the user types.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased().unicodeScalars.filter { $0 != " " })
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, matched: []) }

        let haystack = Array(candidate.unicodeScalars)
        guard haystack.count >= needle.count else { return nil }
        let lowered = Array(candidate.lowercased().unicodeScalars)
        // `lowercased()` can change scalar count (ﬀ, İ). Fall back to a plain
        // containment check rather than indexing two arrays of different lengths.
        guard lowered.count == haystack.count else {
            return candidate.lowercased().contains(query.lowercased())
                ? FuzzyMatch(score: 1, matched: []) : nil
        }

        var score = 0
        var matched: [Int] = []
        matched.reserveCapacity(needle.count)
        var gap = 0
        var index = 0

        for scalar in needle {
            var found = -1
            while index < lowered.count {
                if lowered[index] == scalar {
                    found = index
                    break
                }
                index += 1
                gap += 1
            }
            guard found >= 0 else { return nil }

            if found == 0 {
                score += prefixBonus
            } else if isBoundary(haystack, at: found) {
                score += boundaryBonus
            }
            if matched.last == found - 1 {
                score += adjacencyBonus
            }
            matched.append(found)
            index = found + 1
        }

        score -= min(gap * gapPenalty, maxGapPenalty)
        return FuzzyMatch(score: score, matched: matched)
    }

    /// Whether `index` starts a word: preceded by a separator, or a lowercase
    /// character followed by this uppercase one.
    private static func isBoundary(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        if previous == "." || previous == "/" || previous == "-" || previous == "_"
            || previous == " " || previous == ":" || previous == "?" || previous == "="
        {
            return true
        }
        let properties = scalars[index].properties
        return properties.isUppercase && previous.properties.isLowercase
    }
}

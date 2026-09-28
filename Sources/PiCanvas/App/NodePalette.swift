import AppKit
import Foundation

/// One row in the node switcher.
struct NodePaletteEntry: Equatable {
    var id: UUID
    var kind: NodeKind
    /// What the node's own title bar shows.
    var title: String
    /// Where it runs, abbreviated.
    var subtitle: String
    /// The agent status pill, if any.
    var status: String?
    var statusKind: NodeStatusKind
    /// Whether the agent is waiting for a human.
    var isAttention: Bool
    /// When this node was last focused, for ordering.
    var lastFocused: Date?

    /// Everything a query is matched against. Including the status means typing
    /// "need" finds the agents that want you, which is the most useful thing this
    /// list can do.
    var haystack: String {
        [title, subtitle, status ?? "", kind.displayName].joined(separator: " ")
    }
}

/// Ordering and filtering for the node switcher.
///
/// Split out from the view because it is the part that decides what you get when
/// you type, and therefore the part worth testing.
enum NodePaletteRanking {

    /// How well `query` matches `candidate`. Zero means no match.
    ///
    /// Deliberately simple and explainable: exact, then prefix, then substring
    /// (earlier is better), then a subsequence match with a bonus for hitting the
    /// start of words or path components — so `pc` finds `pi-canvas` and `sp`
    /// finds `~/spero/pi-canvas`.
    static func score(_ query: String, in candidate: String) -> Int {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return 1 }
        let haystack = candidate.lowercased()
        guard !haystack.isEmpty else { return 0 }

        if haystack == needle { return 1400 }
        if haystack.hasPrefix(needle) { return 1000 + needle.count * 4 }
        if let range = haystack.range(of: needle) {
            let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return 700 + max(0, 120 - position * 2)
        }

        var index = haystack.startIndex
        var bonus = 0
        for character in needle {
            guard index < haystack.endIndex,
                  let found = haystack[index...].firstIndex(of: character) else { return 0 }
            if found == haystack.startIndex {
                bonus += 25
            } else {
                let previous = haystack[haystack.index(before: found)]
                if previous == " " || previous == "/" || previous == "-" || previous == "." {
                    bonus += 25
                }
            }
            index = haystack.index(after: found)
        }
        return 300 + bonus
    }

    /// The rows to show, best first.
    ///
    /// With no query: agents that need you, then most recently focused. With a
    /// query: best match first, with the same tiebreaks.
    static func ranked(_ entries: [NodePaletteEntry], query: String) -> [NodePaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return entries.sorted { lhs, rhs in
                if lhs.isAttention != rhs.isAttention { return lhs.isAttention }
                return isMoreRecent(lhs, rhs)
            }
        }

        return entries
            .map { entry -> (entry: NodePaletteEntry, score: Int) in
                let title = score(trimmed, in: entry.title)
                let rest = max(
                    score(trimmed, in: entry.subtitle),
                    score(trimmed, in: entry.status ?? "")
                ) / 2
                return (entry, max(title, rest))
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.isAttention != rhs.entry.isAttention { return lhs.entry.isAttention }
                return isMoreRecent(lhs.entry, rhs.entry)
            }
            .map(\.entry)
    }

    private static func isMoreRecent(_ lhs: NodePaletteEntry, _ rhs: NodePaletteEntry) -> Bool {
        let left = lhs.lastFocused ?? .distantPast
        let right = rhs.lastFocused ?? .distantPast
        if left != right { return left > right }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// A query that is a single digit selects the nth row, so `⌘K` then `2` is a
    /// two-keystroke switch. Returns a zero-based index.
    static func indexForDigit(_ query: String, count: Int) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 1, let digit = Int(trimmed), digit >= 1 else { return nil }
        let index = digit - 1
        return index < count ? index : nil
    }
}

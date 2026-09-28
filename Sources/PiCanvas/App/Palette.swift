import AppKit
import Foundation

/// One row in a palette: a node, a workspace, or an offer to create one.
struct PaletteRow: Equatable {
    var id: UUID
    /// Primary line.
    var title: String
    /// Secondary line, e.g. a directory or a node count.
    var subtitle: String
    /// The status pill, if any.
    var status: String?
    var statusKind: NodeStatusKind
    /// Whether this row is something that wants attention.
    var isAttention: Bool
    /// Colour of the small dot, when the rows are nodes.
    var dotColor: NSColor?
    /// Extra text the query matches against, e.g. a kind name.
    var haystackExtra: String
    /// When this thing was last used, for ordering.
    var lastFocused: Date?
    /// Set on a row whose purpose is to create something; the caller decides what
    /// from `title` and `createName`.
    var createName: String?

    var isCreate: Bool { createName != nil }

    /// Everything a query is matched against. Including the status means typing
    /// "need" finds the agents that want you, which is the most useful thing this
    /// list can do.
    var haystack: String {
        [title, subtitle, status ?? "", haystackExtra].joined(separator: " ")
    }
}

/// What a palette row refers to.
enum PaletteSubject: Equatable {
    case node(UUID)
    case workspace(UUID)
}

/// Ordering and filtering for the node switcher.
///
/// Split out from the view because it is the part that decides what you get when
/// you type, and therefore the part worth testing.
enum PaletteRanking {

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
    static func ranked(_ entries: [PaletteRow], query: String) -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return entries.sorted { lhs, rhs in
                if lhs.isAttention != rhs.isAttention { return lhs.isAttention }
                return isMoreRecent(lhs, rhs)
            }
        }

        return entries
            .map { entry -> (entry: PaletteRow, score: Int) in
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

    private static func isMoreRecent(_ lhs: PaletteRow, _ rhs: PaletteRow) -> Bool {
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

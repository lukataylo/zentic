/// Which tabs moved between two orderings of one window, as a person would say
/// it: dragging one tab moves that tab, not every tab it slid past. Tabs that
/// opened or closed in between are left out — they did not move.
///
/// The tabs that kept their relative order form the longest increasing run of
/// old positions; everything outside it is what moved.
public enum TabMoves {
    public static func moved<ID: Hashable>(from old: [ID], to new: [ID]) -> Set<ID> {
        let oldIndex = Dictionary(old.enumerated().map { ($1, $0) }) { a, _ in a }
        let survivors = new.filter { oldIndex[$0] != nil }
        let positions = survivors.map { oldIndex[$0]! }

        // Patience sorting: `tails[k]` is the index (into `positions`) of the
        // smallest tail of an increasing run of length k + 1.
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: positions.count)
        for (i, position) in positions.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if positions[tails[mid]] < position { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var stayed = Set<ID>()
        var i = tails.last ?? -1
        while i >= 0 {
            stayed.insert(survivors[i])
            i = previous[i]
        }
        return Set(survivors).subtracting(stayed)
    }
}

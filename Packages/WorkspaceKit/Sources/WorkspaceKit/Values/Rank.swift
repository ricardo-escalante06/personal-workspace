/// Fractional-index ranks for manual ordering (sidebar, lists, board columns).
///
/// Ranks are strings compared byte-wise. `Rank.between(a, b)` always returns a
/// string strictly between `a` and `b`, so reordering one item writes one row.
/// Generated ranks never end in "0", which guarantees there is always room below.
public enum Rank {
    static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = 62

    /// A rank for the first item in an empty list.
    public static let initial = "V"

    /// A rank strictly between `lower` and `upper`. `nil` means unbounded on that side.
    public static func between(_ lower: String?, _ upper: String?) -> String {
        let a = Array(lower ?? "")
        var b: [Character]? = upper.map(Array.init)
        if let a2 = lower, let b2 = upper {
            precondition(a2 < b2, "Rank.between requires lower < upper (\(a2), \(b2))")
        }

        var result = ""
        var i = 0
        while true {
            let lo = i < a.count ? index(a[i]) : 0
            let hi: Int
            if let bb = b {
                precondition(i < bb.count, "Rank.between: upper bound exhausted")
                hi = index(bb[i])
            } else {
                hi = base
            }

            if hi - lo > 1 {
                result.append(digits[(lo + hi) / 2])
                return result
            }
            result.append(digits[lo])
            if hi - lo == 1 {
                // Our prefix is now strictly below `upper`; anything after it is fine.
                b = nil
            }
            i += 1
        }
    }

    /// `count` increasing ranks after `lower`, for bulk inserts.
    public static func sequence(count: Int, after lower: String? = nil) -> [String] {
        var ranks: [String] = []
        var previous = lower
        for _ in 0..<count {
            let next = between(previous, nil)
            ranks.append(next)
            previous = next
        }
        return ranks
    }

    private static func index(_ c: Character) -> Int {
        guard let i = digits.firstIndex(of: c) else {
            preconditionFailure("Invalid rank character \(c)")
        }
        return i
    }
}

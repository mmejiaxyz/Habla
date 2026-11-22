import Foundation

/// The English part of `num2words` (LGPL), as misaki uses it: cardinal, ordinal, year and float,
/// always lowercase, no title-casing. The number words themselves are looked up in misaki's
/// lexicon by the caller; this only turns digits into the words they look up.
enum Num2Words {
    // (value, word) in descending order, as num2words inserts them: splitnum() picks the first
    // entry <= value, so the order IS the algorithm. 10^18 (quintillion) is the largest that fits
    // Int64, which also caps the digits `Int()` can parse.
    private static let cards: [(Int, String)] = {
        var out: [(Int, String)] = []
        for (exp, name) in [(18, "quintillion"), (15, "quadrillion"),
                            (12, "trillion"), (9, "billion"), (6, "million")] {
            out.append((ipow10(exp), name))
        }
        for (n, w) in [(1000, "thousand"), (100, "hundred"), (90, "ninety"), (80, "eighty"),
                       (70, "seventy"), (60, "sixty"), (50, "fifty"), (40, "forty"), (30, "thirty")] {
            out.append((n, w))
        }
        for n in stride(from: 20, through: 10, by: -1) {
            out.append((n, ["twenty", "nineteen", "eighteen", "seventeen", "sixteen", "fifteen",
                            "fourteen", "thirteen", "twelve", "eleven", "ten"][20 - n]))
        }
        for n in stride(from: 9, through: 0, by: -1) {
            out.append((n, ["nine", "eight", "seven", "six", "five", "four", "three", "two", "one", "zero"][9 - n]))
        }
        return out
    }()

    private static let ords = ["one": "first", "two": "second", "three": "third", "four": "fourth",
                               "five": "fifth", "six": "sixth", "seven": "seventh", "eight": "eighth",
                               "nine": "ninth", "ten": "tenth", "eleven": "eleventh", "twelve": "twelfth"]

    /// `num2words(int, to='cardinal')`: "1234" -> "one thousand, two hundred and thirty-four".
    static func cardinal(_ value: Int) -> String {
        var out = ""
        var v = value
        if v < 0 { v = -v; out = "minus " }
        let (words, _) = clean(splitnum(v))
        return out + words
    }

    /// `num2words(int, to='ordinal')`: "121" -> "one hundred and twenty-first".
    static func ordinal(_ value: Int) -> String {
        precondition(value >= 0 && value == value, "num2words: ordinal must be a non-negative int")
        var words = cardinal(value).split(separator: " ").map(String.init)
        var last = words[words.count - 1].split(separator: "-").map(String.init)
        let stem = last[last.count - 1]
        last[last.count - 1] = ords[stem] ?? (stem.hasSuffix("y") ? stem.dropLast() + "ieth" : stem + "th")
        words[words.count - 1] = last.joined(separator: "-")
        return words.joined(separator: " ")
    }

    /// `num2words(int, to='year')`: 1789 -> "seventeen eighty-nine", 1905 -> "nineteen oh-five".
    static func year(_ value: Int) -> String {
        var v = value
        var suffix: String? = nil
        if v < 0 { v = -v; suffix = "BC" }
        let (high, low) = (v / 100, v % 100)
        let text: String
        if high == 0 || (high % 10 == 0 && low < 10) || high >= 100 {
            text = cardinal(v)
        } else {
            let highText = cardinal(high)
            let lowText = low == 0 ? "hundred" : low < 10 ? "oh-\(cardinal(low))" : cardinal(low)
            text = "\(highText) \(lowText)"
        }
        return suffix.map { "\(text) \($0)" } ?? text
    }

    /// `num2words(float)`: 2.5 -> "two point five". The precision comes from the float's own
    /// shortest representation, as Python's `Decimal(str(value))` does, so 3.50 -> "three point five".
    static func cardinal(_ value: Double) -> String {
        let neg = value < 0
        let s = String(abs(value))
        var mantissa = s, exp = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(s[..<e])
            exp = Int(s[s.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intDigits = String(parts[0])
        let fracDigits = parts.count > 1 ? String(parts[1]) : ""
        var precision = fracDigits.count - exp          // decimal digits after the point
        if precision < 0 { precision = 0 }
        // digits = |value| * 10^precision, as an integer string.
        var digits = intDigits + fracDigits
        if exp > fracDigits.count { digits += String(repeating: "0", count: exp - fracDigits.count) }
        let pre = Int(intDigits + (exp > 0 ? String(repeating: "0", count: exp) : "")) ?? 0
        let scaled = Int(digits) ?? 0
        var out = [cardinal(neg ? -pre : pre)]
        if precision > 0 {
            out.append("point")
            var post = String(scaled % ipow10(precision))
            while post.count < precision { post = "0" + post }
            for c in post { out.append(cardinal(Int(String(c)) ?? 0)) }
        }
        return out.joined(separator: " ")
    }

    // MARK: - num2words internals

    /// base.splitnum's element: a (text, number) pair or a nested list, whose shape `clean` relies on.
    private enum Node {
        case pair(String, Int)
        case list([Node])
    }

    private static func ipow10(_ e: Int) -> Int {
        var out = 1
        for _ in 0..<e { out *= 10 }
        return out
    }

    /// base.splitnum: greedily the largest card <= value, recursing on the quotient and remainder.
    /// The remainder comes back as a nested list — `clean` pairs it with what precedes it, so the
    /// nesting shape is part of the algorithm (do not flatten).
    private static func splitnum(_ value: Int) -> [Node] {
        for (elem, _) in cards where elem <= value {
            var out: [Node] = []
            let (div, mod) = value == 0 ? (1, 0) : (value / elem, value % elem)
            if div == 1 {
                out.append(.pair("one", 1))
            } else {
                out.append(contentsOf: splitnum(div))
            }
            out.append(.pair(cards.first { $0.0 == elem }!.1, elem))
            if mod != 0 { out.append(.list(splitnum(mod))) }
            return out
        }
        return []
    }

    /// base.clean: repeatedly merge the first two pairs until one remains, keeping nested lists
    /// grouped (they hold the remainder of a division, which merges with its own unit word).
    private static func clean(_ val: [Node]) -> (String, Int) {
        var val = val
        while val.count != 1 {
            var out: [Node] = []
            switch (val[0], val[1]) {
            case (.pair(let l0, let l1), .pair(let r0, let r1)):
                let m = merge((l0, l1), (r0, r1))
                out.append(.pair(m.0, m.1))
                if val.count > 2 { out.append(.list(Array(val[2...]))) }
            default:
                for elem in val {
                    if case .list(let l) = elem {
                        if l.count == 1 {
                            out.append(l[0])
                        } else {
                            let c = clean(l)
                            out.append(.pair(c.0, c.1))
                        }
                    } else {
                        out.append(elem)
                    }
                }
            }
            val = out
        }
        if case .pair(let s, let n) = val[0] { return (s, n) }
        return ("", 0)
    }

    /// lang_EN.merge: the way number words combine (hyphen, and, comma, or multiplication).
    private static func merge(_ l: (String, Int), _ r: (String, Int)) -> (String, Int) {
        if l.1 == 1 && r.1 < 100 { return (r.0, r.1) }
        if 100 > l.1 && l.1 > r.1 { return ("\(l.0)-\(r.0)", l.1 + r.1) }
        if l.1 >= 100 && l.1 > r.1 { return ("\(l.0) and \(r.0)", l.1 + r.1) }
        if r.1 > l.1 { return ("\(l.0) \(r.0)", l.1 * r.1) }
        return ("\(l.0), \(r.0)", l.1 + r.1)
    }
}

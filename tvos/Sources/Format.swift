import Foundation

enum Format {
    /// 703200 -> "703.2K", 9300000 -> "9.3M"
    static func count(_ value: Int?) -> String {
        let n = value ?? 0
        if n >= 1_000_000 {
            return trim(Double(n) / 1_000_000) + "M"
        }
        if n >= 1000 {
            return trim(Double(n) / 1000) + "K"
        }
        return "\(n)"
    }

    private static func trim(_ d: Double) -> String {
        let s = String(format: "%.1f", d)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

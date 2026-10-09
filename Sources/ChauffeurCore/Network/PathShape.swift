import Foundation

/// A request path as an agent may see it (M4b spec §6): no query or fragment, and segments that identify a person or
/// a secret collapsed to `{id}`, `{token}` or `{email}`.
public enum PathShape {
    public static func shape(_ raw: String) -> String {
        let path = raw.prefix { $0 != "?" && $0 != "#" }
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment(String($0)) }
            .joined(separator: "/")
    }

    static func segment(_ raw: String) -> String {
        // Matrix parameters (`;jsessionid=…`) are like a query: dropped.
        let s = String(raw.prefix { $0 != ";" })
        guard !s.isEmpty else { return s }
        // Classify the decoded text, so `%40` and a double-encoded `%2540` are still an `@`.
        var d = s
        for _ in 0..<3 {
            guard let next = d.removingPercentEncoding, next != d else { break }
            d = next
        }
        if d.contains("@") { return "{email}" }
        let digits = d.hasPrefix("+") ? d.dropFirst() : Substring(d)
        if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            !d.hasPrefix("+") || digits.count >= 7
        {
            return "{id}"
        }
        if UUID(uuidString: d) != nil { return "{id}" }
        // A hyphenated slug is mostly words (`iphone-15-pro-max`, `2024-annual-report`), not a token.
        let parts = d.split { $0 == "-" || $0 == "_" }
        let words = parts.filter { $0.count >= 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
        if parts.count > 1 && words.count * 2 >= parts.count { return s }
        // Hex and base64 runs: long, made of token characters, and mixing in a digit (a slug has none).
        if d.count >= 16, d.contains(where: { $0.isASCII && $0.isNumber }),
            d.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=+.".contains($0)) })
        {
            return "{token}"
        }
        return s
    }
}

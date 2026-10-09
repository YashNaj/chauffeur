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

    static func segment(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        if s.contains("@") || s.lowercased().contains("%40") { return "{email}" }
        if s.allSatisfy({ $0.isASCII && $0.isNumber }) || UUID(uuidString: s) != nil { return "{id}" }
        // Hex and base64 runs: long, made of token characters, and mixing in a digit (a slug has none).
        if s.count >= 16, s.contains(where: { $0.isASCII && $0.isNumber }),
            s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=+.".contains($0)) })
        {
            return "{token}"
        }
        return s
    }
}

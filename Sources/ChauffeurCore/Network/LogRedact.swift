import Foundation

/// Apple's networking log lines with every URL shaped like an evidence line (M4b spec §6, "logs follow the same
/// rule"): CFNetwork's error lines carry the full failing URL, query and all, and the agent reads logs too.
public enum LogRedact {
    /// The frameworks whose lines carry request URLs. The app's own lines stay as the developer logged them.
    static let senders: Set<String> = ["CFNetwork", "Network"]

    public static func line(_ line: LogLine) -> LogLine {
        guard let sender = line.sender, senders.contains(sender), line.message.contains("://") else { return line }
        var shaped = line
        shaped.message = urls(in: line.message)
        return shaped
    }

    /// Each `scheme://[user@]host[:port][/path][?query][#fragment]` in `text`, as `scheme://host[:port]` and the
    /// path's shape.
    public static func urls(in text: String) -> String {
        text.replacing(#/([A-Za-z][A-Za-z0-9+.\-]*):\/\/([^\/?#\s,;}\]"'<>()]*)([^\s,;}\]"'<>()]*)/#) { match in
            let (_, scheme, authority, rest) = match.output
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
            return "\(scheme)://\(host)" + (rest.isEmpty ? "" : PathShape.shape(String(rest)))
        }
    }
}

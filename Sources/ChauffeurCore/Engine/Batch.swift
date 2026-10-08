import Foundation

/// `do` scripts (spec §5.1): commands separated by `;` or newlines, words split like a shell — double quotes (where
/// `\"` and `\\` are escapes), single quotes (literal) and backslash escapes outside quotes. A `;` inside quotes is text.
public enum Batch {
    public static let maxCommands = 50

    public static func parse(_ script: String) throws -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        for c in script {
            if escaped {
                // "\n" in double quotes stays as typed
                if quote == "\"" && c != "\"" && c != "\\" { word.append("\\") }
                word.append(c)
                escaped = false
                continue
            }
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\" && q == "\"" {
                    escaped = true
                } else {
                    word.append(c)
                }
                continue
            }
            switch c {
            case "\\":
                escaped = true
                inWord = true
            case "\"", "'":
                quote = c
                inWord = true
            case ";", "\n": endCommand()
            case " ", "\t": endWord()
            default:
                word.append(c)
                inWord = true
            }
        }
        if let quote { throw ChauffeurError.usage("unterminated \(quote) quote in the do script") }
        if escaped { throw ChauffeurError.usage("the do script ends with a lone backslash") }
        endCommand()
        return commands
    }

    /// One command as a line for messages: words with spaces, quotes or controls are quoted and escaped.
    public static func render(_ argv: [String]) -> String {
        argv.map { w in
            let plain = !w.isEmpty && !w.contains { " \t;\"'\\".contains($0) || $0.isNewline }
            return plain ? w : Perception.quote(w, limit: 200)
        }.joined(separator: " ")
    }
}

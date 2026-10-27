import Foundation

public enum ConnectError: Error, Equatable, CustomStringConvertible {
    case badKeyFile(String)

    public var description: String {
        switch self {
        case .badKeyFile(let text): return text
        }
    }
}

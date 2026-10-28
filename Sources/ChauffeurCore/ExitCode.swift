/// The exit codes chauffeur returns, in the order the usage text lists them.
public enum ExitCode: Int32, CaseIterable {
    case ok = 0
    case error = 1
    case noEffect = 3
    case notFound = 4
    case crashed = 5
    case pending = 6
    case usage = 64

    /// This code's fragment of the usage text's "exit codes:" line.
    public var line: String {
        switch self {
        case .ok: return "\(rawValue) ok"
        case .error: return "\(rawValue) error"
        case .noEffect: return "\(rawValue) action had no verified effect"
        case .notFound: return "\(rawValue) not found"
        case .crashed: return "\(rawValue) app crashed"
        case .pending: return "\(rawValue) effect still in flight (chauffeur wait)"
        case .usage: return "\(rawValue) usage"
        }
    }
}

extension Output {
    /// The one mapping from an error to an output: usage mistakes exit 64, everything else 1, with the error's own text.
    public static func failure(_ error: any Error) -> Output {
        switch error {
        case ChauffeurError.usage(let text): return Output(text, exit: .usage)
        case let error as ChauffeurError: return Output(error.description, exit: .error)
        case let error as RefError: return Output(error.description, exit: .error)
        case let error as ConnectError: return Output(error.description, exit: .error)
        case let error as MCPToolError: return Output(error.message, exit: .error)
        default: return Output("\(error)", exit: .error)
        }
    }
}

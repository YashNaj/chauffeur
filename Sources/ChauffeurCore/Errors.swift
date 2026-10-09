import Foundation

/// Every error chauffeur reports. `description` always says what to do next.
public enum ChauffeurError: Error, Equatable, CustomStringConvertible {
    case simulatorServiceUnresponsive(command: String)
    case noBootedSimulator
    case severalBooted([String])
    case unknownTarget(String, known: [String])
    case ambiguousTarget(String, matches: [String])
    case notBooted(String)
    case bridge(String)
    case noTree
    case blind(String)
    /// The app in front has no tree and chauffeur knows which app it is: `withRelaunch` can recover (M4b spec §8).
    case needsRelaunch(bundle: String, why: String)
    case landscape
    case usage(String)
    case daemon(String)
    /// A step that failed with its own explanation (simctl or image errors).
    case failed(String)

    /// The front app's first tree isn't up: `launch` and `wait` keep polling instead of failing or recovering.
    public var appNotUpYet: Bool {
        switch self {
        case .noTree, .blind, .needsRelaunch: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .simulatorServiceUnresponsive(let command):
            return "simulator service unresponsive (`\(command)` timed out). Check `uptime` for memory pressure; "
                + "if it persists: killall -9 com.apple.CoreSimulator.CoreSimulatorService"
        case .noBootedSimulator:
            return "no booted simulator. Boot one (xcrun simctl boot <udid>) or pin one with: chauffeur use <name|udid>"
        case .severalBooted(let devices):
            return "several simulators are booted:\n" + devices.map { "  " + $0 }.joined(separator: "\n")
                + "\npass --udid <udid> or run: chauffeur use <name|udid>"
        case .unknownTarget(let name, let known):
            return "no simulator matches \"\(name)\". Available:\n" + known.map { "  " + $0 }.joined(separator: "\n")
        case .ambiguousTarget(let name, let matches):
            return "\"\(name)\" matches several simulators:\n" + matches.map { "  " + $0 }.joined(separator: "\n")
                + "\nuse the udid instead"
        case .notBooted(let udid):
            return "simulator \(udid) is not booted. Boot it with: xcrun simctl boot \(udid)"
        case .bridge(let message):
            return "simulator bridge failed: \(message). Run: chauffeur doctor"
        case .noTree:
            return "no accessibility tree yet (app still launching, or nothing in the foreground). "
                + "Retry, or run: chauffeur doctor"
        case .blind(let why):
            return why
        case .needsRelaunch(_, let why):
            return why
        case .landscape:
            return "the screen is in landscape; M1 supports portrait only. Rotate back (Device ▸ Rotate in Simulator)"
        case .usage(let text):
            return text
        case .daemon(let message):
            return "daemon: \(message)"
        case .failed(let message):
            return message
        }
    }
}

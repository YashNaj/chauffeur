import Foundation

/// The simulator `Session` drives: `Device` in production, a fake in tests.
@MainActor
public protocol SimDevice: AnyObject {
    var udid: String { get }
    var booted: Bool { get }
    var size: Size { get }
}

/// What the touch log says about a touch: `TouchLog` in production, a scripted source in tests.
public protocol TouchEvidenceSource: AnyObject {
    var isAttached: Bool { get }
    var cursor: Int { get }
    func start() throws
    func stop()
    func evidence(since cursor: Int, waitMs: Int) -> Evidence
}

/// The launched app's unified log: `LogTap` in production, a scripted ring in tests.
public protocol LogSource: AnyObject {
    var isAttached: Bool { get }
    /// The executable whose log is followed while the stream is attached.
    var executable: String? { get }
    var cursor: Int { get }
    var all: [LogLine] { get }
    func since(_ cursor: Int) -> [LogLine]
    /// False when `log stream` did not attach; following the same executable again keeps the lines.
    @discardableResult func start(executable: String) -> Bool
    func stop()
    /// Tests feed lines; `LogTap` shapes URLs as it stores them.
    func append(_ line: LogLine)
}

/// How `Session` runs `xcrun simctl`: through `SimCtl` in production, recorded in tests.
public protocol ShellRunner: Sendable {
    /// `xcrun simctl <args>`; throws `ChauffeurError.simulatorServiceUnresponsive` on timeout, as `SimCtl.run` does.
    @discardableResult
    func simctl(_ args: [String], stdin: String?, timeout: Double) throws -> ProcessResult
}

extension ShellRunner {
    // Protocol requirements cannot carry default arguments, so these keep call sites as short as `SimCtl.run`.
    @discardableResult
    public func simctl(_ args: [String]) throws -> ProcessResult {
        try simctl(args, stdin: nil, timeout: 30)
    }

    @discardableResult
    public func simctl(_ args: [String], stdin: String?) throws -> ProcessResult {
        try simctl(args, stdin: stdin, timeout: 30)
    }

    @discardableResult
    public func simctl(_ args: [String], timeout: Double) throws -> ProcessResult {
        try simctl(args, stdin: nil, timeout: timeout)
    }
}

/// Host process facts: `Proc` in production, a fixed set in tests.
public protocol ProcessTable: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func parent(of pid: Int32) -> Int32?
    func children(of parent: Int32, named: String) -> [Int32]
}

/// `ProcessTable` over the host's real processes.
public struct LiveProcessTable: ProcessTable {
    public init() {}
    public func isAlive(_ pid: Int32) -> Bool { Proc.isAlive(pid) }
    public func parent(of pid: Int32) -> Int32? { Proc.parent(pid) }
    public func children(of parent: Int32, named name: String) -> [Int32] {
        Proc.children(of: parent, named: name)
    }
}

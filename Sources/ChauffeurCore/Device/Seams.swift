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

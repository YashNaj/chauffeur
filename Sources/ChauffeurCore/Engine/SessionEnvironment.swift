import Foundation

/// Everything `Session` reaches outside itself: the clock, the simulator, its accessibility tree, the touch log,
/// `simctl`, the network flows and the host's processes. `.live` in the daemon; tests script each one.
public struct SessionEnvironment {
    public var clock: any SettleClock
    public var device: @MainActor (String) throws -> any SimDevice
    public var ax: @MainActor (any SimDevice) throws -> any AXSource
    public var touchEvidence: any TouchEvidenceSource
    public var shell: any ShellRunner
    /// Built on the first tap, at most once; nil when NetworkStatistics is unavailable.
    public var flows: @MainActor () -> (any FlowSource)?
    public var processes: any ProcessTable

    /// The real simulator: CoreSimulator, the accessibility bridge, the touch log, `simctl`, NetworkStatistics, `Proc`.
    public static func live(udid: String) -> SessionEnvironment {
        SessionEnvironment(
            clock: SystemClock(),
            device: { try Device(udid: $0) },
            ax: { device in
                // The one place a `SimDevice` must be a `Device`: the bridge reads the tree through its `CHSimulator`.
                guard let d = device as? Device else {
                    throw ChauffeurError.bridge("the accessibility bridge needs a CoreSimulator device")
                }
                return try AXProvider(sim: d.sim)
            },
            touchEvidence: TouchLog(udid: udid, levelFile: StatePaths.level(udid)),
            shell: SimCtlRunner(),
            flows: { try? NetStatsSource() },
            processes: LiveProcessTable())
    }
}

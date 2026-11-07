import Foundation

/// Everything `Session` reaches outside itself: the clock, the simulator, its accessibility tree, the touch log,
/// `simctl`, the network flows, the host's processes, the boot state, the crash report, the input device, the
/// launched app's log and the project's telemetry entries. `.live` in the daemon; tests script each one.
public struct SessionEnvironment {
    public var clock: any SettleClock
    public var device: @MainActor (String) throws -> any SimDevice
    public var ax: @MainActor (any SimDevice) throws -> any AXSource
    public var touchEvidence: any TouchEvidenceSource
    public var shell: any ShellRunner
    /// Built on the first tap, at most once; nil when NetworkStatistics is unavailable.
    public var flows: @MainActor () -> (any FlowSource)?
    public var processes: any ProcessTable
    /// Is the simulator booted (nil: could not tell), when did its current boot start, and the report for a gone app.
    public var simulatorBooted: () -> Bool?
    public var simulatorBootDate: () -> Date?
    public var findCrashReport: (TrackedApp) -> CrashReport?
    /// Touches, keys and buttons for a connected device; the session keeps it until it drops the device.
    public var inputs: @MainActor (any SimDevice) throws -> any InputDevice
    /// The launched app's unified log.
    public var logs: any LogSource
    /// The project's telemetry entries for a directory (M4b spec §4).
    public var telemetry: (URL) -> [String]

    /// The real simulator: CoreSimulator, the accessibility bridge, the touch log, `simctl`, NetworkStatistics, `Proc`,
    /// and the nearest `.chauffeur.json`.
    public static func live(udid: String) -> SessionEnvironment {
        SessionEnvironment(
            clock: SystemClock(),
            device: { try Device(udid: $0) },
            ax: { device in
                // The two places a `SimDevice` must be a `Device`: the bridge reads the tree and sends input through
                // its `CHSimulator`.
                guard let d = device as? Device else {
                    throw ChauffeurError.bridge("the accessibility bridge needs a CoreSimulator device")
                }
                return try AXProvider(sim: d.sim)
            },
            touchEvidence: TouchLog(udid: udid, levelFile: StatePaths.level(udid)),
            shell: SimCtlRunner(),
            flows: { try? NetStatsSource() },
            processes: LiveProcessTable(),
            simulatorBooted: { SimBoot.booted(udid: udid) },
            simulatorBootDate: { SimBoot.date(udid: udid) },
            findCrashReport: { app in
                CrashFinder.find(bundle: app.bundle, pid: app.pid, udid: udid, since: app.launchedAt)
            },
            inputs: { device in
                guard let d = device as? Device else {
                    throw ChauffeurError.bridge("HID input needs a CoreSimulator device")
                }
                return HID(device: d)
            },
            logs: LogTap(udid: udid),
            telemetry: { Target.telemetryHosts(from: $0) })
    }
}

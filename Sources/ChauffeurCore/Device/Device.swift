import ChauffeurBridge
import Foundation

/// One simulator, resolved through CoreSimulator.
@MainActor
public final class Device: SimDevice {
    public let udid: String
    public let sim: CHSimulator
    public let simulatorKitPath: String

    public init(udid: String) throws {
        self.udid = udid
        let developerDir = Xcode.developerDir()
        do {
            simulatorKitPath = try Self.loadFrameworks(developerDir: developerDir)
            sim = try CHSimulator(udid: udid, developerDir: developerDir)
        } catch {
            throw ChauffeurError.bridge(error.localizedDescription)
        }
    }

    /// Loads CoreSimulator and SimulatorKit from `developerDir` and returns SimulatorKit's path. Throws the bridge's
    /// own error, which `doctor` shows as it is.
    public static func loadFrameworks(developerDir: String) throws -> String {
        try CHSimulator.loadFrameworks(developerDir: developerDir)
    }

    public var size: Size { Size(w: Double(sim.pointSize.width), h: Double(sim.pointSize.height)) }
    public var booted: Bool { sim.isBooted }
}

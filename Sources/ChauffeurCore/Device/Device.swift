import ChauffeurBridge
import Foundation

/// One simulator, resolved through CoreSimulator.
@MainActor
public final class Device {
    public let sim: CHSimulator
    public let simulatorKitPath: String

    public init(udid: String) throws {
        let developerDir = Xcode.developerDir()
        do {
            simulatorKitPath = try CHSimulator.loadFrameworks(developerDir: developerDir)
            sim = try CHSimulator(udid: udid, developerDir: developerDir)
        } catch {
            throw ChauffeurError.bridge(error.localizedDescription)
        }
    }

    public var size: Size { Size(w: Double(sim.pointSize.width), h: Double(sim.pointSize.height)) }
    public var booted: Bool { sim.isBooted }
}

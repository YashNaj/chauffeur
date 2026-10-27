import CryptoKit
import Foundation

@testable import ChauffeurCore

enum TestKeys {
    static let issuer = "69a6de70-03db-47e3-a96a-7ee2dc5a4c3b"
    static let keyID = "7X2K9ABC1D"

    static func pem() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }

    static func key() throws -> ConnectKey {
        try ConnectKey(pem: pem(), keyID: keyID, issuer: issuer)
    }
}

@testable import DeviceHubTransport
import Testing

@Suite("Display name text")
struct DisplayNameTextTests {
    /// Format characters (ZWJ in emoji sequences, bidi marks) are ordinary in
    /// device names; only C0/C1 control characters are rejected, as in Rust.
    private let formattedNames = [
        "👨‍💻 iPad",
        "🏳️‍🌈 iPhone",
        "iPhone\u{200E}",
        "山田のiPhone"
    ]

    @Test("the controller name accepts emoji sequences and format characters")
    func controllerNames() throws {
        for name in formattedNames {
            let configuration = try DeviceHubTransportConfiguration(
                controllerDisplayName: name,
                controllerModel: "iPad16,3",
                remoteTargetPolicy: .authenticatedDevices
            )
            #expect(configuration.controllerDisplayName == name)
        }
        #expect(throws: NativeSessionContractError.invalidText) {
            try DeviceHubTransportConfiguration(
                controllerDisplayName: "iPad\u{0007}",
                controllerModel: "iPad16,3",
                remoteTargetPolicy: .authenticatedDevices
            )
        }
    }

    @Test("peer names from pairing accept format characters but not controls")
    func peerNames() throws {
        for name in formattedNames {
            try NativeSessionValidation.requireText(name, maximumUTF8Length: 128)
        }
        for name in ["iPhone\u{0000}", "iPhone\u{009F}", "a\nb"] {
            #expect(throws: NativeSessionContractError.invalidText) {
                try NativeSessionValidation.requireText(name, maximumUTF8Length: 128)
            }
        }
    }
}

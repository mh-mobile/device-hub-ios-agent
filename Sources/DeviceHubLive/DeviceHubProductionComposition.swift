import DeviceHubTransport
import Foundation

/// Owns the shipping transport values that make Device Hub appear as a
/// compatible Pairable Host to an iOS target.
public enum DeviceHubProductionComposition {
    private static let controllerNamePrefix = "Device Hub App in "
    private static let maximumControllerNameUTF8Length = 128

    /// Creates the transport configuration used by the production app.
    ///
    /// The user-assigned device name disambiguates multiple iPhone and iPad
    /// controllers in the target's nearby-device picker.
    public static func makeTransportConfiguration(
        controllerDeviceName: String
    ) throws
        -> DeviceHubTransportConfiguration
    {
        try DeviceHubTransportConfiguration(
            controllerDisplayName: controllerDisplayName(
                deviceName: controllerDeviceName
            ),
            controllerModel: "Mac17,7",
            remoteTargetPolicy: .authenticatedDevices
        )
    }

    private static func controllerDisplayName(
        deviceName: String
    ) -> String {
        let remainingByteCount =
            maximumControllerNameUTF8Length
                - controllerNamePrefix.utf8.count
        var suffix = ""
        var suffixByteCount = 0

        for character in deviceName {
            let characterByteCount = String(character).utf8.count
            guard
                suffixByteCount + characterByteCount
                <= remainingByteCount
            else {
                break
            }
            suffix.append(character)
            suffixByteCount += characterByteCount
        }
        // A cut right after a space would leave trailing whitespace, which
        // the transport rejects as invalid display text.
        return (controllerNamePrefix + suffix).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
}

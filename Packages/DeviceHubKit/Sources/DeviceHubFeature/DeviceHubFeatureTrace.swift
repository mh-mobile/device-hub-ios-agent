import Foundation

/// Emits opt-in, identity-free reducer milestones for physical-device diagnosis.
enum DeviceHubFeatureTrace {
    static func emit(_ message: String) {
        guard
            ProcessInfo.processInfo.environment[
                "DEVICE_HUB_BOOTSTRAP_TRACE"
            ] == "1"
        else {
            return
        }
        FileHandle.standardOutput.write(
            Data("devicehub.feature \(message)\n".utf8)
        )
    }
}

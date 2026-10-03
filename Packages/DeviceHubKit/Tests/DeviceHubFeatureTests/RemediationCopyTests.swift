import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

/// Recovery copy may say Device Hub is reconnecting only while a reconnect is
/// actually scheduled.
@MainActor
@Suite("Remediation copy follows the reconnect state")
struct RemediationCopyTests {
    @Test("an ended session says it reconnects only while attempts remain")
    func endedSessionCopyFollowsTheBudget() throws {
        let device = device(id: "device", name: "Test iPhone")
        var session = try connectedSession(device: device, receivedAt: Date(timeIntervalSince1970: 6200))
        session.sessionID = nil
        session.connectionError = .connectionLost
        var state = RemoteSessionFeature.State(
            remediation: DeviceHubRemediation(error: .connectionLost),
            roster: DeviceRoster(devices: [device]),
            selectedDeviceID: device.id,
            session: session
        )

        #expect(state.reconnectsAutomatically)
        #expect(state.presentedRemediation?.message == DeviceHubError.connectionLost.userFacing.message)

        state.reconnectAttempts = RemoteSessionFeature.maximumReconnectAttempts
        #expect(!state.reconnectsAutomatically)
        #expect(state.presentedRemediation?.message == DeviceHubError.connectionLost.manualRecoveryMessage)
    }

    @Test("a failed command on a live session does not claim a reconnect")
    func failedCommandCopyIsManual() throws {
        let device = device(id: "device", name: "Test iPhone")
        var session = try connectedSession(device: device, receivedAt: Date(timeIntervalSince1970: 6300))
        session.connectionError = .connectionLost
        let state = RemoteSessionFeature.State(
            remediation: DeviceHubRemediation(error: .connectionLost),
            roster: DeviceRoster(devices: [device]),
            selectedDeviceID: device.id,
            session: session
        )

        #expect(!state.reconnectsAutomatically)
        #expect(state.presentedRemediation?.message == DeviceHubError.connectionLost.manualRecoveryMessage)
    }

    @Test("a pairing failure never claims a reconnect")
    func pairingFailureCopyIsManual() async {
        let store = TestStore(initialState: PairingFeature.State()) {
            PairingFeature()
        }
        store.exhaustivity = .off

        await store.send(.pairingFailed(.connectionLost))

        #expect(store.state.remediation?.message == DeviceHubError.connectionLost.manualRecoveryMessage)
    }
}

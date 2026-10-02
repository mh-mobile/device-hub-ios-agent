import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session recovery")
struct RemoteSessionRecoveryTests {
    @Test("returning from background through inactive restarts discovery")
    func foregroundAfterBackgroundRestartsDiscovery() async {
        let store = TestStore(
            initialState: RemoteSessionFeature.State(lifecycle: .background)
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub.pairedDevices = { [] }
        }

        await store.send(.appLifecycleChanged(.inactive)) {
            $0.lifecycle = .inactive
        }
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }
        await store.receive(\.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isLoadingRoster = false
        }
    }

    @Test("a brief inactive phase while observing does not reload")
    func inactiveWhileObservingDoesNotReload() async {
        let store = TestStore(
            initialState: RemoteSessionFeature.State(isObservingAvailability: true)
        ) {
            RemoteSessionFeature()
        }

        await store.send(.appLifecycleChanged(.inactive)) {
            $0.lifecycle = .inactive
        }
        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
        }
    }

    @Test("availability observation that ends is restarted after a delay")
    func availabilityRestartsAfterEnding() async {
        let clock = TestClock()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(isObservingAvailability: true)
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.pairedDevices = { [] }
        }

        await store.send(.availabilityObservationFinished) {
            $0.isObservingAvailability = false
        }
        await clock.advance(by: RemoteSessionFeature.recoveryDelay)
        await store.receive(\.task) {
            $0.isLoadingRoster = true
        }
        await store.receive(\.pairedDevicesResponse) {
            $0.isLoadingRoster = false
        }
    }

    @Test("a retryable session failure reconnects the selected device after a delay")
    func retryableFailureReconnects() async throws {
        let time = Date(timeIntervalSince1970: 5200)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(current.sessionID)
        let clock = TestClock()
        let nextAttempt = fixtureUUID(90)
        let connects = LockIsolated(0)
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = .constant(nextAttempt)
            $0.deviceHub.connect = { _ in
                connects.withValue { $0 += 1 }
                throw CancellationError()
            }
        }
        store.exhaustivity = .off

        await store.send(
            .sessionStreamFailed(
                attemptID: current.attemptID,
                sessionID: sessionID,
                error: .connectionLost
            )
        )
        #expect(store.state.remediation?.error == .connectionLost)
        await clock.advance(by: RemoteSessionFeature.recoveryDelay)
        await store.receive(\.reconnectTimerFired)

        #expect(store.state.session?.attemptID == nextAttempt)
        #expect(store.state.remediation == nil)
        await store.finish()
        #expect(connects.value == 1)
    }

    @Test("a failure that needs the user does not reconnect by itself")
    func userActionFailureDoesNotReconnect() async throws {
        let time = Date(timeIntervalSince1970: 5300)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(current.sessionID)
        let clock = TestClock()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(
            .sessionStreamFailed(
                attemptID: current.attemptID,
                sessionID: sessionID,
                error: .needsPairing
            )
        ) {
            $0.remediation = DeviceHubRemediation(error: .needsPairing)
            $0.session?.connectionError = .needsPairing
            $0.session?.sessionID = nil
        }
        await clock.advance(by: .seconds(60))
    }
}

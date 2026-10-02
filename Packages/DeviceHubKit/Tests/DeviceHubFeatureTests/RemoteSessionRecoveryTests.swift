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

    @Test("returning to active during a session restarts discovery without reloading")
    func activeDuringSessionDoesNotReload() async throws {
        let time = Date(timeIntervalSince1970: 5900)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let snapshots = AsyncStream<[DeviceSummary]>.makeStream()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                lifecycle: .inactive,
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.deviceHub.availability = { snapshots.stream }
            // A reload reports every device unavailable until discovery
            // catches up, which would show the live device as offline.
            $0.deviceHub.pairedDevices = {
                [DeviceHubFeatureTests.device(
                    id: "device",
                    name: "Test iPhone",
                    reachability: .unavailable
                )]
            }
        }

        await store.send(.appLifecycleChanged(.active)) {
            $0.lifecycle = .active
            $0.isObservingAvailability = true
        }
        await store.skipInFlightEffects()
    }

    @Test("availability observation that ends is restarted without reloading the roster")
    func availabilityRestartsAfterEnding() async {
        let clock = TestClock()
        let snapshots = AsyncStream<[DeviceSummary]>.makeStream()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(isObservingAvailability: true)
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.deviceHub.availability = { snapshots.stream }
        }

        await store.send(.availabilityObservationFinished) {
            $0.isObservingAvailability = false
        }
        await clock.advance(by: RemoteSessionFeature.recoveryDelay)
        await store.receive(\.availabilityRestartDue) {
            $0.isObservingAvailability = true
        }
        snapshots.continuation.finish()
        await store.receive(\.availabilityObservationFinished) {
            $0.isObservingAvailability = false
        }
        await store.skipInFlightEffects()
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

    @Test(
        "reconnecting while the previous session is still closing is not cancelled",
        .timeLimit(.minutes(1))
    )
    func reconnectDuringCloseCompletes() async throws {
        let device = device(id: "device", name: "Test iPhone")
        let closing = AsyncStream<Void>.makeStream()
        let connecting = AsyncStream<Void>.makeStream()
        let sessions = LockIsolated(0)
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = Date(timeIntervalSince1970: 5400)
            $0.uuid = .incrementing
            $0.deviceHub.connect = { _ in
                let index = sessions.withValue { value -> Int in
                    value += 1
                    return value
                }
                if index == 2 {
                    // The new connection is still in progress when the
                    // previous close finishes.
                    for await _ in connecting.stream {
                        break
                    }
                }
                return DeviceSession(
                    id: DeviceSessionID(rawValue: fixtureUUID(UInt8(100 + index))),
                    device: device,
                    events: AsyncThrowingStream { _ in },
                    frames: AsyncStream { _ in },
                    command: { _ in },
                    disconnect: {
                        // The first session takes a while to close.
                        guard index == 1 else {
                            return
                        }
                        for await _ in closing.stream {
                            return
                        }
                    }
                )
            }
        }
        store.exhaustivity = .off

        await store.send(.availabilitySnapshotReceived([device]))
        await store.receive(\.connectionResponse)
        let first = try #require(store.state.session)
        try await store.send(
            .sessionStreamFailed(
                attemptID: first.attemptID,
                sessionID: #require(first.sessionID),
                error: .deviceBusy
            )
        )
        await store.send(.retrySelectedDevice)
        closing.continuation.yield()
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        connecting.continuation.yield()

        await store.receive(\.connectionResponse)
        #expect(store.state.session?.sessionID != nil)
        #expect(sessions.value == 2)
        await store.skipInFlightEffects()
    }

    @Test("a reconnect that comes due while briefly inactive waits and still happens")
    func reconnectSurvivesAnInactivePhase() async throws {
        let time = Date(timeIntervalSince1970: 5500)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(current.sessionID)
        let clock = TestClock()
        let connects = LockIsolated(0)
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                isObservingAvailability: true,
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.date.now = time
            $0.uuid = .incrementing
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
        await store.send(.appLifecycleChanged(.inactive))
        await clock.advance(by: RemoteSessionFeature.recoveryDelay)
        await store.receive(\.reconnectTimerFired)
        #expect(connects.value == 0)

        await store.send(.appLifecycleChanged(.active))
        await clock.advance(by: RemoteSessionFeature.recoveryDelay)
        await store.receive(\.reconnectTimerFired)
        await store.finish()
        #expect(connects.value == 1)
    }

    @Test(
        "a failed input release while closing keeps the error that ended the session",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func cleanupFailureKeepsEndingError(unpaired: Bool) async throws {
        let device = device(id: "device", name: "Test iPhone")
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = Date(timeIntervalSince1970: 5600)
            $0.uuid = .incrementing
            $0.deviceHub.connect = { _ in
                DeviceSession(
                    id: DeviceSessionID(rawValue: fixtureUUID(110)),
                    device: device,
                    events: AsyncThrowingStream { _ in },
                    frames: AsyncStream { _ in },
                    // The executor has already shut down.
                    command: { _ in throw DeviceHubError.connectionLost },
                    disconnect: {}
                )
            }
        }
        store.exhaustivity = .off

        await store.send(.availabilitySnapshotReceived([device]))
        await store.receive(\.connectionResponse)
        let session = try #require(store.state.session)
        let endingError: DeviceHubError
        if unpaired {
            endingError = .needsPairing
            var revoked = device
            revoked.pairingState = .requiresPairing
            await store.send(.availabilitySnapshotReceived([revoked]))
        } else {
            endingError = .secureConnectionFailed
            try await store.send(
                .sessionStreamFailed(
                    attemptID: session.attemptID,
                    sessionID: #require(session.sessionID),
                    error: endingError
                )
            )
        }
        await store.receive(\.inputCleanupFailed)

        #expect(store.state.remediation == DeviceHubRemediation(error: endingError))
        #expect(store.state.session?.connectionError == endingError)
        #expect(store.state.session?.sessionID == nil)
        await store.finish()
    }

    @Test(
        "automatic reconnects back off and stop until the user retries",
        .timeLimit(.minutes(1))
    )
    func reconnectsBackOffAndStop() async throws {
        let time = Date(timeIntervalSince1970: 5700)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(current.sessionID)
        let clock = TestClock()
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
            $0.uuid = .incrementing
            $0.deviceHub.connect = { _ in
                connects.withValue { $0 += 1 }
                throw DeviceHubError.deviceOffline
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
        var delay = RemoteSessionFeature.recoveryDelay
        for attempt in 1 ... RemoteSessionFeature.maximumReconnectAttempts {
            await clock.advance(by: delay - .milliseconds(1))
            #expect(connects.value == attempt - 1)
            await clock.advance(by: .milliseconds(1))
            await store.receive(\.connectionResponse)
            #expect(connects.value == attempt)
            delay *= 2
        }
        await clock.advance(by: .seconds(3600))
        #expect(connects.value == RemoteSessionFeature.maximumReconnectAttempts)

        await store.send(.retrySelectedDevice)
        await store.receive(\.connectionResponse)
        await clock.advance(by: RemoteSessionFeature.recoveryDelay)
        await store.receive(\.connectionResponse)
        #expect(connects.value == RemoteSessionFeature.maximumReconnectAttempts + 2)
        await store.skipInFlightEffects()
    }
}

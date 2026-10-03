import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session reconnect budget")
struct RemoteSessionReconnectTests {
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

    @Test("switching to another device starts its reconnect count over")
    func reconnectCountIsPerDevice() async {
        let first = device(id: "first", name: "First iPhone")
        let second = device(id: "second", name: "Second iPhone")
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                isViewingStopped: true,
                reconnectAttempts: RemoteSessionFeature.maximumReconnectAttempts,
                roster: DeviceRoster(devices: [first, second]),
                selectedDeviceID: first.id
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = Date(timeIntervalSince1970: 6100)
            $0.uuid = .incrementing
            $0.deviceHub.connect = { _ in throw DeviceHubError.deviceOffline }
        }
        store.exhaustivity = .off

        // The first device leaves the roster, so the selection moves on.
        await store.send(.availabilitySnapshotReceived([second]))

        #expect(store.state.selectedDeviceID == second.id)
        #expect(store.state.reconnectAttempts == 0)
        await store.skipInFlightEffects()
    }

    @Test("a reconnect that finds the device unreachable does not use up an attempt")
    func unreachableReconnectKeepsTheCount() async throws {
        let time = Date(timeIntervalSince1970: 6000)
        let reachable = device(id: "device", name: "Test iPhone")
        let unreachable = device(id: "device", name: "Test iPhone", reachability: .unavailable)
        var current = try connectedSession(device: reachable, receivedAt: time)
        current.sessionID = nil
        current.connectionError = .connectionLost
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                reconnectAttempts: 2,
                roster: DeviceRoster(devices: [unreachable]),
                selectedDeviceID: unreachable.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = time
        }
        store.exhaustivity = .off

        await store.send(.reconnectTimerFired(attemptID: current.attemptID))

        #expect(store.state.reconnectAttempts == 2)
    }

    /// Written out rather than derived from `retryability`, so a wrong
    /// classification fails here instead of being mirrored by the test.
    @Test(
        "only transient failures reconnect on their own",
        .timeLimit(.minutes(1)),
        arguments: [
            (DeviceHubError.connectionLost, true),
            (.deviceOffline, true),
            (.mediaStalled, true),
            (.secureConnectionFailed, false),
            (.decoderFailed, false),
            (.needsPairing, false),
            (.deviceLocked, false)
        ]
    )
    func reconnectsOnlyAfterTransientFailures(error: DeviceHubError, reconnects: Bool) async throws {
        let time = Date(timeIntervalSince1970: 6400)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
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
                throw CancellationError()
            }
        }
        store.exhaustivity = .off

        try await store.send(
            .sessionStreamFailed(
                attemptID: current.attemptID,
                sessionID: #require(current.sessionID),
                error: error
            )
        )
        await clock.advance(by: .seconds(60))
        if reconnects {
            await store.receive(\.reconnectTimerFired)
        }
        await store.finish()

        #expect(connects.value == (reconnects ? 1 : 0), "\(error)")
    }
}

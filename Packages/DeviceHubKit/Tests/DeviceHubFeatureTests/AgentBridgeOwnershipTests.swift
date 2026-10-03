import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

/// The agent API may drive only the session the app shows and authorizes,
/// through the same ownership checks as the canvas.
@MainActor
@Suite("Agent bridge ownership")
struct AgentBridgeOwnershipTests {
    @Test("the agent holds the shown frame only while input is allowed, and loses it on stop")
    func grantFollowsInputAuthority() async throws {
        let time = Date(timeIntervalSince1970: 6600)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(current.sessionID)
        let generation = try #require(current.remoteState?.generation)
        let bridge = AgentBridge()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.agentBridge = bridge
            $0.continuousClock = TestClock()
            $0.date.now = time
        }
        store.exhaustivity = .off

        let frame = try remoteFrame(generation: generation, receivedAt: time, sequenceNumber: 2)
        await store.send(.frameReceived(attemptID: current.attemptID, sessionID: sessionID, frame: frame))
        await store.finish()
        let size = try bridge.screenSize()
        #expect(size.width == 2 && size.height == 2)

        // Commands go through the coordinator's ownership checks: this test's
        // coordinator owns no live session, so the command is refused rather
        // than sent to a session it does not own.
        await #expect(throws: DeviceHubError.connectionLost) {
            try await bridge.tap(x: 1, y: 1)
        }

        await store.send(.stopViewingButtonTapped)
        await store.finish()
        #expect(throws: AgentBridge.Failure.self) { try bridge.screenSize() }
        #expect(throws: AgentBridge.Failure.self) { try bridge.screenshotPNG() }
        await #expect(throws: AgentBridge.Failure.self) {
            try await bridge.tap(x: 1, y: 1)
        }
    }

    @Test("a briefly inactive app revokes the agent too")
    func inactiveRevokesTheGrant() async throws {
        let time = Date(timeIntervalSince1970: 6700)
        let device = device(id: "device", name: "Test iPhone")
        let current = try connectedSession(device: device, receivedAt: time)
        let sessionID = try #require(current.sessionID)
        let generation = try #require(current.remoteState?.generation)
        let bridge = AgentBridge()
        let store = TestStore(
            initialState: RemoteSessionFeature.State(
                roster: DeviceRoster(devices: [device]),
                selectedDeviceID: device.id,
                session: current
            )
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.agentBridge = bridge
            $0.continuousClock = TestClock()
            $0.date.now = time
        }
        store.exhaustivity = .off

        let frame = try remoteFrame(generation: generation, receivedAt: time, sequenceNumber: 2)
        await store.send(.frameReceived(attemptID: current.attemptID, sessionID: sessionID, frame: frame))
        await store.finish()
        _ = try bridge.screenSize()
        await store.send(.appLifecycleChanged(.inactive))
        await store.finish()
        #expect(throws: AgentBridge.Failure.self) { try bridge.screenSize() }
    }
}

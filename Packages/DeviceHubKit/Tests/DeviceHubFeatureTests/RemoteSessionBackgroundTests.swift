import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import DeviceHubFeature
import Foundation
import Testing

@MainActor
@Suite("Remote session backgrounding")
struct RemoteSessionBackgroundTests {
    @Test(
        "closing the session on background runs inside protected background time",
        .timeLimit(.minutes(1))
    )
    func backgroundCloseIsProtected() async throws {
        let time = Date(timeIntervalSince1970: 4600)
        let device = device(id: "device", name: "Test iPhone")
        let context = RotationSessionTestContext(
            time: time,
            device: device,
            attemptID: fixtureUUID(80),
            sessionID: DeviceSessionID(rawValue: fixtureUUID(81)),
            generation: SessionGeneration(rawValue: fixtureUUID(82))
        )
        let events = AsyncThrowingStream<SessionUpdate, Error>.makeStream()
        let frames = AsyncStream<RemoteDisplayFrame>.makeStream()
        let log = ProtectionLog()
        let session = DeviceSession(
            id: context.sessionID,
            device: device,
            events: events.stream,
            frames: frames.stream,
            command: { _ in },
            disconnect: { await log.append("disconnect") }
        )
        let store = TestStore(
            initialState: RemoteSessionFeature.State()
        ) {
            RemoteSessionFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date.now = time
            $0.deviceHub.connect = { _ in session }
            $0.uuid = .constant(context.attemptID)
            $0.backgroundExecution = BackgroundExecutionClient { name, work in
                await log.append("begin \(name)")
                await work()
                await log.append("end \(name)")
            }
        }
        try await establishInputReadyRotationSession(in: store, context: context)

        await store.send(.appLifecycleChanged(.background)) {
            $0.lifecycle = .background
            $0.session = nil
        }
        await log.waitForCount(3)

        let entries = await log.entries
        expectNoDifference(entries, [
            "begin close-remote-session",
            "disconnect",
            "end close-remote-session"
        ])
    }
}

private actor ProtectionLog {
    private(set) var entries: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ entry: String) {
        entries.append(entry)
        waiters.removeAll { waiter in
            guard entries.count >= waiter.0 else {
                return false
            }
            waiter.1.resume()
            return true
        }
    }

    func waitForCount(_ count: Int) async {
        guard entries.count < count else {
            return
        }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

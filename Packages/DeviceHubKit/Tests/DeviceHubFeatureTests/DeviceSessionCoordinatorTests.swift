import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@Suite("Device session coordinator ordering")
struct DeviceSessionCoordinatorTests {
    @Test("a new connection starts only after the previous session finished disconnecting")
    func replaceWaitsForTeardown() async throws {
        let log = OrderLog()
        let gate = Gate()
        let target = device(id: "device", name: "Test iPhone")
        let first = DeviceSession(
            id: DeviceSessionID(rawValue: fixtureUUID(70)),
            device: target,
            events: AsyncThrowingStream { $0.finish() },
            frames: AsyncStream { $0.finish() },
            command: { _ in },
            disconnect: {
                await log.append("disconnect-started")
                await gate.wait()
                await log.append("disconnect-finished")
            }
        )
        let second = DeviceSession(
            id: DeviceSessionID(rawValue: fixtureUUID(71)),
            device: target,
            events: AsyncThrowingStream { $0.finish() },
            frames: AsyncStream { $0.finish() },
            command: { _ in },
            disconnect: {}
        )
        let sessions = SessionQueue([first, second])
        var client = DeviceHubClient.testValue
        client.connect = { _ in
            let session = await sessions.next()
            await log.append("connect-\(session.id == first.id ? 1 : 2)")
            return session
        }
        let coordinator = DeviceSessionCoordinator()
        let firstAttempt = fixtureUUID(72)
        let secondAttempt = fixtureUUID(73)

        _ = try await coordinator.replace(
            attemptID: firstAttempt,
            deviceID: target.id,
            using: client
        )
        let closing = Task { await coordinator.close(attemptID: firstAttempt) }
        await log.waitFor("disconnect-started")
        let connecting = Task {
            try await coordinator.replace(
                attemptID: secondAttempt,
                deviceID: target.id,
                using: client
            )
        }
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        await gate.open()
        _ = await closing.value
        _ = try await connecting.value

        let entries = await log.entries
        #expect(entries == [
            "connect-1",
            "disconnect-started",
            "disconnect-finished",
            "connect-2"
        ])
    }
}

private actor OrderLog {
    private(set) var entries: [String] = []
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

    func append(_ entry: String) {
        entries.append(entry)
        waiters.removeAll { waiter in
            guard waiter.0 == entry else {
                return false
            }
            waiter.1.resume()
            return true
        }
    }

    func waitFor(_ entry: String) async {
        guard !entries.contains(entry) else {
            return
        }
        await withCheckedContinuation { waiters.append((entry, $0)) }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor SessionQueue {
    private var sessions: [DeviceSession]

    init(_ sessions: [DeviceSession]) {
        self.sessions = sessions
    }

    func next() -> DeviceSession {
        sessions.removeFirst()
    }
}

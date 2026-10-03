import DeviceHubClient
import DeviceHubCore
import Foundation

/// Serializes ownership changes around the one active transport session.
///
/// This imperative shell is intentionally actor-isolated. Attempt-scoped
/// ownership prevents stale effects from disconnecting a newer target, and
/// media-scoped revocation prevents late commands from crossing a cleanup
/// barrier after input authorization has been withdrawn.
actor DeviceSessionCoordinator {
    private struct OwnedSession {
        let attemptID: UUID
        var revokedInputMetadata: ScreenMetadata?
        let session: DeviceSession
    }

    private var activeSession: OwnedSession?
    private var latestAttemptID: UUID?
    /// The most recent close or connection attempt, which `replace` awaits
    /// so a new connection never overlaps the previous session's input
    /// release and disconnect.
    private var teardown: Task<Void, Never>?

    func command(
        _ command: DeviceCommand,
        attemptID: UUID,
        sessionID: DeviceSessionID,
        authorization: ScreenMetadata
    ) async throws {
        guard let activeSession,
              activeSession.attemptID == attemptID,
              activeSession.session.id == sessionID
        else {
            throw DeviceHubError.connectionLost
        }
        guard activeSession.revokedInputMetadata != authorization else {
            throw CancellationError()
        }
        try await activeSession.session.command(command)
    }

    /// Revokes one exact media authorization and enqueues the cleanup barrier.
    func releaseAllInput(
        attemptID: UUID,
        sessionID: DeviceSessionID,
        revoking authorization: ScreenMetadata
    ) async -> DeviceHubError? {
        guard var activeSession,
              activeSession.attemptID == attemptID,
              activeSession.session.id == sessionID
        else {
            return nil
        }
        guard activeSession.revokedInputMetadata != authorization else {
            return nil
        }
        activeSession.revokedInputMetadata = authorization
        self.activeSession = activeSession

        do {
            try await activeSession.session.command(.releaseAllInput)
            return nil
        } catch {
            return mapCleanupError(error)
        }
    }

    /// Closes only the matching attempt after cleanup has entered its FIFO.
    func close(attemptID: UUID) async -> DeviceHubError? {
        if latestAttemptID == attemptID {
            latestAttemptID = nil
        }
        guard let activeSession,
              activeSession.attemptID == attemptID
        else {
            return nil
        }

        self.activeSession = nil
        let session = activeSession.session
        let previousTeardown = teardown
        let closing = Task { () -> DeviceHubError? in
            await previousTeardown?.value
            let cleanupError: DeviceHubError?
            do {
                try await session.command(.releaseAllInput)
                cleanupError = nil
            } catch {
                cleanupError = mapCleanupError(error)
            }
            await session.disconnect()
            return cleanupError
        }
        teardown = Task { _ = await closing.value }
        return await closing.value
    }

    func replace(
        attemptID: UUID,
        deviceID: DeviceID,
        using client: DeviceHubClient
    ) async throws -> DeviceSession {
        try Task.checkCancellation()
        latestAttemptID = attemptID

        // This attempt joins the chain until it either owns the session or
        // has disconnected it, so a connect still in flight when Stop arrives
        // (close finds nothing to close) never overlaps the next one.
        let previousTeardown = teardown
        let (attemptSettled, settle) = AsyncStream<Never>.makeStream()
        defer { settle.finish() }
        teardown = Task {
            await previousTeardown?.value
            for await _ in attemptSettled {}
        }
        await previousTeardown?.value
        guard !Task.isCancelled, latestAttemptID == attemptID else {
            throw CancellationError()
        }
        let session = try await client.connect(deviceID)
        guard !Task.isCancelled,
              latestAttemptID == attemptID
        else {
            await session.disconnect()
            throw CancellationError()
        }
        guard activeSession == nil else {
            await session.disconnect()
            throw DeviceHubError.connectionLost
        }
        activeSession = OwnedSession(
            attemptID: attemptID,
            revokedInputMetadata: nil,
            session: session
        )
        return session
    }

    private func mapCleanupError(_ error: any Error) -> DeviceHubError {
        if let error = error as? DeviceHubError {
            return error
        }
        if error is CancellationError {
            return .connectionLost
        }
        return .secureConnectionFailed
    }
}

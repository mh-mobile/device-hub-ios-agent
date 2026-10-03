import Foundation

/// Serializes diagnostic recording around the pure retention buffer and
/// delegates all I/O to injected boundaries.
public actor DiagnosticRecorder {
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var buffer: DiagnosticBuffer
    private let context: DiagnosticWireContext
    private let now: @Sendable () -> Date
    private var nextSequence: UInt64
    private let policy: DiagnosticRetentionPolicy
    private let persistence: DiagnosticPersistenceClient
    private let uploader: DiagnosticUploadClient

    /// Creates a recorder whose new events retain `context` in the local
    /// outbox. Restored events keep their original context instead.
    public init(
        context: DiagnosticWireContext,
        policy: DiagnosticRetentionPolicy,
        persistence: DiagnosticPersistenceClient,
        uploader: DiagnosticUploadClient,
        now: @escaping @Sendable () -> Date
    ) throws {
        buffer = try DiagnosticBuffer(policy: policy)
        self.context = context
        self.policy = policy
        self.persistence = persistence
        self.uploader = uploader
        self.now = now
        nextSequence = 1
    }

    /// Restores the latest persisted snapshot and reapplies the current
    /// retention policy before accepting new events.
    public func restore() async throws {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }

        guard !Task.isCancelled else {
            throw DiagnosticError.cancelled(.restoration)
        }

        let data: Data?
        do {
            data = try await persistence.load()
        } catch {
            throw DiagnosticError.persistence(error)
        }

        guard let data else {
            return
        }

        let snapshot = try DiagnosticSnapshot.decode(data)
        let restoredBuffer = try DiagnosticBuffer(
            policy: policy,
            snapshot: snapshot
        )

        let lastSequence = snapshot.events.map(\.sequence).max() ?? 0
        guard lastSequence < .max else {
            throw DiagnosticError.sequenceExhausted
        }

        buffer = restoredBuffer
        nextSequence = lastSequence + 1
    }

    /// Records and persists one structured event before returning.
    @discardableResult
    public func record(
        level: DiagnosticLevel,
        category: DiagnosticCategory,
        stage: DiagnosticStage,
        kind: DiagnosticEventKind,
        fields: DiagnosticFields = DiagnosticFields()
    ) async throws -> DiagnosticRecordResult {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }

        guard !Task.isCancelled else {
            throw DiagnosticError.cancelled(.recording)
        }

        let event = DiagnosticEvent(
            sequence: nextSequence,
            timestamp: now(),
            level: level,
            category: category,
            stage: stage,
            kind: kind,
            fields: fields
        )
        nextSequence += 1

        let retention = try buffer.append(
            event,
            context: context
        )
        if !retention.droppedIncomingEvent {
            let data = try buffer.snapshot.encoded()
            do {
                try await persistence.save(data)
            } catch {
                throw DiagnosticError.persistence(error)
            }
        }

        return DiagnosticRecordResult(event: event, retention: retention)
    }

    /// Prunes expired events transactionally, uploads the retained outbox when
    /// the app enters the foreground, and clears it only after upload succeeds.
    public func flushOnForeground() async throws -> DiagnosticFlushResult {
        await acquireExclusiveOperation()
        defer { releaseExclusiveOperation() }

        guard !Task.isCancelled else {
            throw DiagnosticError.cancelled(.foregroundFlush)
        }
        guard !buffer.events.isEmpty else {
            return .nothingToFlush
        }

        let expirationThreshold = now().addingTimeInterval(
            -DiagnosticSnapshot.maximumUploadAge
        )
        // Events dated too far ahead (a clock that ran fast) are dropped as
        // well: the wire format rejects them, which would wedge the outbox.
        let futureThreshold = now().addingTimeInterval(
            DiagnosticSnapshot.maximumFutureSkew
        )
        let retainedSnapshot = buffer.snapshot.retainingEvents {
            $0.timestamp >= expirationThreshold && $0.timestamp <= futureThreshold
        }
        let expiredEventCount =
            buffer.events.count - retainedSnapshot.events.count

        if expiredEventCount > 0 {
            guard !Task.isCancelled else {
                throw DiagnosticError.cancelled(.foregroundFlush)
            }

            try await replaceBuffer(with: retainedSnapshot)
            if retainedSnapshot.events.isEmpty {
                return .discardedExpiredEvents(
                    eventCount: expiredEventCount
                )
            }
        }

        let data = try buffer.snapshot.encoded()
        let eventCount = buffer.events.count

        do {
            try await uploader.upload(data)
        } catch .cancelled {
            throw DiagnosticError.cancelled(.foregroundFlush)
        } catch {
            try await keepUndeliveredEvents(after: error)
            throw DiagnosticError.upload(error.stoppingFailure)
        }

        guard !Task.isCancelled else {
            throw DiagnosticError.cancelled(.foregroundFlush)
        }

        do {
            try await persistence.clear()
        } catch {
            throw DiagnosticError.persistence(error)
        }

        buffer = try DiagnosticBuffer(policy: policy)
        return .flushed(
            eventCount: eventCount,
            expiredEventCount: expiredEventCount,
            encodedByteCount: data.count
        )
    }

    /// After a failed upload, drops what the server already accepted, so it is
    /// not sent again under a new batch ID once eviction shifts the batches,
    /// and drops everything when the server will never accept it.
    private func keepUndeliveredEvents(
        after failure: DiagnosticUploadFailure
    ) async throws {
        if failure.isPermanent {
            try await replaceBuffer(with: buffer.snapshot.retainingEvents { _ in false })
        } else if case let .partiallyDelivered(deliveredThrough, _) = failure {
            try await replaceBuffer(
                with: buffer.snapshot.retainingEvents { $0.sequence > deliveredThrough }
            )
        }
    }

    /// Persists `snapshot` (or clears storage when it is empty) and makes it
    /// the buffer.
    private func replaceBuffer(with snapshot: DiagnosticSnapshot) async throws {
        do {
            if snapshot.events.isEmpty {
                try await persistence.clear()
            } else {
                try await persistence.save(snapshot.encoded())
            }
        } catch let error as DiagnosticPersistenceFailure {
            throw DiagnosticError.persistence(error)
        }
        buffer = snapshot.events.isEmpty
            ? try DiagnosticBuffer(policy: policy)
            : try DiagnosticBuffer(policy: policy, snapshot: snapshot)
    }

    /// Returns the current retained snapshot without performing I/O.
    public func snapshot() -> DiagnosticSnapshot {
        buffer.snapshot
    }

    private func acquireExclusiveOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseExclusiveOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }

        operationWaiters.removeFirst().resume()
    }
}

import CustomDump
@testable import DeviceHubDiagnostics
import Foundation
import Testing

struct DiagnosticRecorderExpiryTests {
    @Test func foregroundFlushPrunesExpiredEventsBeforePersistenceAndUpload() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let persisted = try DiagnosticSnapshot(
            context: context,
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(
                        -(7 * 24 * 60 * 60) - 0.001
                    ),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                ),
                DiagnosticEvent(
                    sequence: 2,
                    timestamp: now.addingTimeInterval(-7 * 24 * 60 * 60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            ]
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persisted)
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        let result = try await recorder.flushOnForeground()

        let savedPayloads = await persistence.savedPayloads
        let uploadedPayloads = await uploader.uploadedPayloads
        let prunedPayload = try #require(savedPayloads.last)
        let uploadedPayload = try #require(uploadedPayloads.first)
        try expectNoDifference(
            DiagnosticSnapshot.decode(prunedPayload).events.map(\.sequence),
            [2]
        )
        expectNoDifference(uploadedPayload, prunedPayload)
        expectNoDifference(
            result,
            .flushed(
                eventCount: 1,
                expiredEventCount: 1,
                encodedByteCount: uploadedPayload.count
            )
        )
    }

    /// A clock that ran ahead once must not wedge the outbox: the wire format
    /// rejects events dated more than five minutes ahead, so pruning drops them.
    @Test func foregroundFlushDropsEventsDatedTooFarAhead() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let persisted = try DiagnosticSnapshot(
            context: context,
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(-60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                ),
                DiagnosticEvent(
                    sequence: 2,
                    timestamp: now.addingTimeInterval(10 * 60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            ]
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persisted)
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        _ = try await recorder.flushOnForeground()

        let uploadedPayload = try #require(await uploader.uploadedPayloads.first)
        try expectNoDifference(
            DiagnosticSnapshot.decode(uploadedPayload).events.map(\.sequence),
            [1]
        )
    }

    @Test(arguments: [
        (DiagnosticUploadFailure.rejected(statusCode: 400), [UInt64]()),
        (.rejected(statusCode: 422), []),
        (.rejected(statusCode: 429), [1, 2]),
        (.rejected(statusCode: 503), [1, 2]),
        (.transportFailed, [1, 2]),
        (.partiallyDelivered(throughSequence: 1, failure: .transportFailed), [2]),
        (.partiallyDelivered(throughSequence: 1, failure: .rejected(statusCode: 400)), []),
        (.partiallyDelivered(throughSequence: 1, failure: .cancelled), [2])
    ])
    func failedFlushKeepsOnlyWhatCanStillBeDelivered(
        failure: DiagnosticUploadFailure,
        retained: [UInt64]
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let persisted = try DiagnosticSnapshot(
            context: context,
            events: (1 ... 2).map {
                DiagnosticEvent(
                    sequence: $0,
                    timestamp: now.addingTimeInterval(-60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            }
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persisted)
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: UploadProbe(failure: failure).client,
            now: { now }
        )
        try await recorder.restore()

        // A cancellation still reads as one to the caller, whatever was sent.
        let expected: DiagnosticError? = failure.stoppingFailure == .cancelled
            ? .cancelled(.foregroundFlush)
            : nil
        do {
            _ = try await recorder.flushOnForeground()
            Issue.record("The failed upload unexpectedly flushed.")
        } catch let error as DiagnosticError {
            if let expected {
                #expect(error == expected)
            }
        }

        // Delivered events are dropped so a later batch cannot resend them
        // under a new batch ID; a permanent rejection drops the rest too.
        let remaining = await recorder.snapshot().events.map(\.sequence)
        expectNoDifference(remaining, retained)
    }

    @Test func entirelyExpiredSnapshotIsRemovedWithoutStartingTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let persisted = try DiagnosticSnapshot(
            context: context,
            events: [
                DiagnosticEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                    level: .info,
                    category: .connection,
                    stage: .ready,
                    kind: .operationSucceeded
                )
            ]
        ).encoded()
        let persistence = PersistenceProbe(loadedPayload: persisted)
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        let result = try await recorder.flushOnForeground()
        let uploadedPayloads = await uploader.uploadedPayloads
        let savedPayloads = await persistence.savedPayloads
        let clearCount = await persistence.clearCount
        let retainedEvents = await recorder.snapshot().events

        expectNoDifference(
            result,
            .discardedExpiredEvents(eventCount: 1)
        )
        expectNoDifference(uploadedPayloads, [])
        expectNoDifference(savedPayloads, [])
        expectNoDifference(clearCount, 1)
        expectNoDifference(retainedEvents, [])
    }

    @Test func expiryPruningFailureRetainsTheOriginalSnapshotAndSkipsTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_753_207_200)
        let context = try diagnosticContext()
        let events = [
            DiagnosticEvent(
                sequence: 1,
                timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60),
                level: .info,
                category: .connection,
                stage: .ready,
                kind: .operationSucceeded
            ),
            DiagnosticEvent(
                sequence: 2,
                timestamp: now,
                level: .info,
                category: .connection,
                stage: .ready,
                kind: .operationSucceeded
            )
        ]
        let persistence = try PersistenceProbe(
            loadedPayload: DiagnosticSnapshot(
                context: context,
                events: events
            ).encoded(),
            saveFailure: .writingFailed
        )
        let uploader = UploadProbe()
        let recorder = try DiagnosticRecorder(
            context: context,
            policy: DiagnosticRetentionPolicy(
                maximumEventCount: 10,
                maximumEncodedByteCount: 32 * 1024
            ),
            persistence: persistence.client,
            uploader: uploader.client,
            now: { now }
        )
        try await recorder.restore()

        await #expect(
            throws: DiagnosticError.persistence(.writingFailed)
        ) {
            try await recorder.flushOnForeground()
        }

        let retainedEvents = await recorder.snapshot().events
        let uploadedPayloads = await uploader.uploadedPayloads
        let clearCount = await persistence.clearCount
        expectNoDifference(retainedEvents, events)
        expectNoDifference(uploadedPayloads, [])
        expectNoDifference(clearCount, 0)
    }
}

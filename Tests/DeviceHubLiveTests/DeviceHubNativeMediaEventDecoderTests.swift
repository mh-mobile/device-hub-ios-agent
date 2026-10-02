import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

@Suite("Native media event decoding")
struct DeviceHubNativeMediaEventDecoderTests {
    let generation = SessionGeneration(
        rawValue: UUID(
            uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
        )!
    )

    @Test("the media plane is contiguous and starts independently at one")
    func contiguousMediaSequence() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var datagramBytes = Data([0x01])

        #expect(
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &datagramBytes
            ) == .datagram(
                DeviceHubNativeVideoDatagram(
                    sequenceNumber: 1,
                    sourcePort: 50001,
                    bytes: Data([0x01])
                )
            )
        )

        var parameterSets = ParameterSets()
        #expect(
            try decodeConfiguration(
                with: &decoder,
                sequence: 2,
                revision: 7,
                parameterSets: &parameterSets
            ) == .configuration(
                DeviceHubNativeVideoConfiguration(
                    sequenceNumber: 2,
                    revision: 7,
                    pixelSize: PixelSize(width: 1290, height: 2796),
                    orientation: .portrait,
                    videoParameterSet: parameterSets.video,
                    sequenceParameterSet: parameterSets.sequence,
                    pictureParameterSet: parameterSets.picture
                )
            )
        )

        var accessUnitBytes = Data([0, 0, 0, 2, 0x26, 0x01])
        #expect(
            try decodeAccessUnit(
                with: &decoder,
                sequence: 3,
                parameterSetRevision: 7,
                bytes: &accessUnitBytes
            ) == .accessUnit(
                DeviceHubNativeVideoAccessUnit(
                    sequenceNumber: 3,
                    parameterSetRevision: 7,
                    synchronizationSource: 0x1234_5678,
                    rtpTimestamp: 0x9ABC_DEF0,
                    firstRTPSequenceNumber: 65534,
                    lastRTPSequenceNumber: 1,
                    isSync: true,
                    geometry: DeviceHubNativeMediaGeometry(
                        pixelSize: PixelSize(
                            width: 1290,
                            height: 2796
                        ),
                        orientation: .landscapeLeft,
                        isOrientationLocked: false
                    ),
                    bytes: Data([0, 0, 0, 2, 0x26, 0x01])
                )
            )
        )

        #expect(
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 4,
                reason: DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP
            ) == .discontinuity(
                DeviceHubNativeVideoDiscontinuity(
                    sequenceNumber: 4,
                    reason: .sequenceGap
                )
            )
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidSequence
        ) {
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 6,
                reason: DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM
            )
        }
        #expect(
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 5,
                reason: DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM
            ) == .discontinuity(
                DeviceHubNativeVideoDiscontinuity(
                    sequenceNumber: 5,
                    reason: .unexpectedStream
                )
            )
        )
    }

    @Test(
        "native receiver accepts datagrams without a redundant Swift decoder"
    )
    func nativeReceiverOnlyDatagram() async throws {
        let ingests = LockedCounter()
        let pipe = AsyncThrowingStream<
            NativeSessionEvent,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(4))
        let context = DeviceHubNativeCallbackContext(
            generation: generation,
            controlContinuation: pipe.continuation,
            relay: DeviceHubNativeSessionRelay(),
            avConference: DeviceHubAVConferenceSession(
                operations: .init(
                    configureAndStart: { _ in },
                    ingest: { _ in
                        ingests.increment()
                    },
                    invalidate: {},
                    makeOffer: { Data([0x01]) }
                )
            )
        )
        let bytes = Data([0x80, 0x60, 0x00, 0x01])

        bytes.withUnsafeBytes { buffer in
            var datagram = DhVideoDatagram()
            datagram.bytes = nativeBytes(buffer)
            datagram.source_port = 50001
            withUnsafePointer(to: &datagram) { datagramPointer in
                withMediaEvent(
                    kind: DH_EVENT_VIDEO_DATAGRAM,
                    mutate: { $0.video_datagram = datagramPointer },
                    operation: {
                        context.handleMedia($0)
                    }
                )
            }
        }
        context.finishAfterTeardown()

        var controlEvents: [NativeSessionEvent] = []
        for try await event in pipe.stream {
            controlEvents.append(event)
        }
        #expect(ingests.count == 1)
        #expect(controlEvents.isEmpty)
    }

    @Test("every borrowed byte span is copied before callback return")
    func borrowedBytesAreCopied() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var datagramBytes = Data([0xAA, 0xBB, 0xCC])
        let datagram = try decodeDatagram(
            with: &decoder,
            sequence: 1,
            bytes: &datagramBytes
        )
        datagramBytes.resetBytes(in: datagramBytes.indices)

        var parameterSets = ParameterSets()
        let configuration = try decodeConfiguration(
            with: &decoder,
            sequence: 2,
            revision: 11,
            parameterSets: &parameterSets
        )
        parameterSets.video.resetBytes(in: parameterSets.video.indices)
        parameterSets.sequence.resetBytes(in: parameterSets.sequence.indices)
        parameterSets.picture.resetBytes(in: parameterSets.picture.indices)

        var accessUnitBytes = Data([0, 0, 0, 2, 0x02, 0x01])
        let accessUnit = try decodeAccessUnit(
            with: &decoder,
            sequence: 3,
            parameterSetRevision: 11,
            bytes: &accessUnitBytes
        )
        accessUnitBytes.resetBytes(in: accessUnitBytes.indices)

        guard case let .datagram(copiedDatagram) = datagram,
              case let .configuration(copiedConfiguration) = configuration,
              case let .accessUnit(copiedAccessUnit) = accessUnit
        else {
            Issue.record("Expected three copied media values")
            return
        }
        #expect(copiedDatagram.bytes == Data([0xAA, 0xBB, 0xCC]))
        #expect(
            copiedConfiguration.videoParameterSet
                == ParameterSets().video
        )
        #expect(
            copiedConfiguration.sequenceParameterSet
                == ParameterSets().sequence
        )
        #expect(
            copiedConfiguration.pictureParameterSet
                == ParameterSets().picture
        )
        #expect(
            copiedAccessUnit.bytes
                == Data([0, 0, 0, 2, 0x02, 0x01])
        )
    }

    @Test("exact envelope, generation, and successful sequence are required")
    func envelopeValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try decoder.decodeMedia(nil)
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.struct_size &-= 1 },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.abi_version &+= 1 },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.reserved = 1 },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.staleGeneration
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                generation: DhGeneration(high: 99, low: 100)
            ) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidSequence
        ) {
            try withMediaEvent(
                sequence: 2,
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP)
            ) {
                try decoder.decodeMedia($0)
            }
        }

        #expect(
            try decodeDiscontinuity(
                with: &decoder,
                sequence: 1,
                reason: DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP
            ) == .discontinuity(
                DeviceHubNativeVideoDiscontinuity(
                    sequenceNumber: 1,
                    reason: .sequenceGap
                )
            )
        )
    }

    @Test("media callbacks reject control kinds and non-media envelope data")
    func exactMediaEnvelope() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.unsupportedEvent
        ) {
            try withMediaEvent(kind: DH_EVENT_SESSION_STARTED) {
                try decoder.decodeMedia($0)
            }
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.state = DH_SESSION_STATE_READY },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.phase = DH_CONNECTION_PHASE_READY },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.request_id = 1 },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: { $0.image_width = 1 },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidEnvelope
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64(DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP),
                mutate: {
                    $0.payload = DhBytes(
                        data: UnsafePointer<UInt8>(bitPattern: 1),
                        count: 1
                    )
                },
                operation: {
                    try decoder.decodeMedia($0)
                }
            )
        }
    }
}

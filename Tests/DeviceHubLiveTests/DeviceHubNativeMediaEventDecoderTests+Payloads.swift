import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

extension DeviceHubNativeMediaEventDecoderTests {
    @Test("datagrams validate pointer shape, reserved bytes, port, and size")
    func datagramValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(kind: DH_EVENT_VIDEO_DATAGRAM) {
                try decoder.decodeMedia($0)
            }
        }

        var empty = Data()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &empty
            )
        }

        var byte = Data([0x01])
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                sourcePort: 0,
                bytes: &byte
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &byte,
                mutate: { $0.reserved.0 = 1 }
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &byte,
                nativeBytes: DhBytes(data: nil, count: 1)
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeDatagram(
                with: &decoder,
                sequence: 1,
                bytes: &byte,
                nativeBytes: DhBytes(
                    data: UnsafePointer<UInt8>(bitPattern: 1),
                    count:
                    DeviceHubNativeMediaEventDecoder
                        .maximumDatagramByteCount + 1
                )
            )
        }
    }

    @Test("configurations validate revisions, dimensions, orientation, and spans")
    func configurationValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var parameterSets = ParameterSets()

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(kind: DH_EVENT_VIDEO_CONFIGURATION) {
                try decoder.decodeMedia($0)
            }
        }

        for mutation in [
            ConfigurationMutation.revision(0),
            .pixelWidth(0),
            .pixelHeight(0),
            .pixelWidth(
                UInt32(
                    DeviceHubNativeMediaEventDecoder.maximumPixelDimension
                        + 1
                )
            ),
            .orientation(UInt32.max),
            .reserved
        ] {
            #expect(
                throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
            ) {
                try decodeConfiguration(
                    with: &decoder,
                    sequence: 1,
                    revision: 7,
                    parameterSets: &parameterSets,
                    mutate: mutation.apply
                )
            }
        }

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                eventValue: 8,
                parameterSets: &parameterSets
            )
        }

        parameterSets.video = Data()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                parameterSets: &parameterSets
            )
        }

        parameterSets = ParameterSets()
        parameterSets.video = Data([0x42, 0x01])
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                parameterSets: &parameterSets
            )
        }

        parameterSets = ParameterSets()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 7,
                parameterSets: &parameterSets,
                overrideVideoBytes: DhBytes(
                    data: UnsafePointer<UInt8>(bitPattern: 1),
                    count:
                    DeviceHubNativeMediaEventDecoder
                        .maximumParameterSetByteCount + 1
                )
            )
        }
    }

    @Test("configuration preserves flat and unresolved valid orientations")
    func configurationOrientation() throws {
        var flatDecoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var flatSets = ParameterSets()
        let flat = try decodeConfiguration(
            with: &flatDecoder,
            sequence: 1,
            revision: 1,
            parameterSets: &flatSets,
            mutate: { $0.orientation = DH_ORIENTATION_LANDSCAPE_RIGHT }
        )
        guard case let .configuration(flatConfiguration) = flat else {
            Issue.record("Expected a configuration")
            return
        }
        #expect(flatConfiguration.orientation == .landscapeRight)
        #expect(
            flatConfiguration.pixelSize
                == PixelSize(width: 2796, height: 1290)
        )

        for rawOrientation in [
            DH_ORIENTATION_UNKNOWN,
            DH_ORIENTATION_FACE_UP,
            DH_ORIENTATION_FACE_DOWN
        ] {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            var parameterSets = ParameterSets()
            let decoded = try decodeConfiguration(
                with: &decoder,
                sequence: 1,
                revision: 1,
                parameterSets: &parameterSets,
                mutate: { $0.orientation = rawOrientation }
            )
            guard case let .configuration(configuration) = decoded else {
                Issue.record("Expected a configuration")
                continue
            }
            #expect(configuration.orientation == nil)
        }
    }

    @Test("access units validate revisions, flags, geometry, and byte bounds")
    func accessUnitValidation() throws {
        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var bytes = Data([0, 0, 0, 2, 0x02, 0x01])

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(kind: DH_EVENT_VIDEO_ACCESS_UNIT) {
                try decoder.decodeMedia($0)
            }
        }

        for mutation in [
            AccessUnitMutation.revision(0),
            .isSync(2),
            .reserved,
            .pixelWidth(0),
            .pixelHeight(0),
            .pixelHeight(
                UInt32(
                    DeviceHubNativeMediaEventDecoder.maximumPixelDimension
                        + 1
                )
            ),
            .orientationLocked(2),
            .geometryReserved
        ] {
            #expect(
                throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
            ) {
                try decodeAccessUnit(
                    with: &decoder,
                    sequence: 1,
                    parameterSetRevision: 7,
                    bytes: &bytes,
                    mutate: mutation.apply
                )
            }
        }

        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                eventValue: 8,
                bytes: &bytes
            )
        }

        var empty = Data()
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                bytes: &empty
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                bytes: &bytes,
                nativeBytes: DhBytes(data: nil, count: 1)
            )
        }
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 7,
                bytes: &bytes,
                nativeBytes: DhBytes(
                    data: UnsafePointer<UInt8>(bitPattern: 1),
                    count:
                    DeviceHubNativeMediaEventDecoder
                        .maximumAccessUnitByteCount + 1
                )
            )
        }
    }

    @Test("non-flat access-unit orientation uses the validated fallback")
    func geometryOrientationFallback() throws {
        for primary in [
            DH_ORIENTATION_UNKNOWN,
            DH_ORIENTATION_FACE_UP,
            DH_ORIENTATION_FACE_DOWN
        ] {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            var bytes = Data([0, 0, 0, 2, 0x02, 0x01])
            let decoded = try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 1,
                bytes: &bytes,
                mutate: {
                    $0.geometry.orientation = primary
                    $0.geometry.non_flat_orientation =
                        DH_ORIENTATION_PORTRAIT_UPSIDE_DOWN
                    $0.geometry.orientation_locked = 1
                }
            )
            guard case let .accessUnit(accessUnit) = decoded else {
                Issue.record("Expected an access unit")
                continue
            }
            #expect(
                accessUnit.geometry.orientation == .portraitUpsideDown
            )
            #expect(accessUnit.geometry.isOrientationLocked)
        }

        for mutation in [
            AccessUnitMutation.orientation(UInt32.max),
            .fallback(UInt32.max)
        ] {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            var bytes = Data([0, 0, 0, 2, 0x02, 0x01])
            #expect(
                throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
            ) {
                try decodeAccessUnit(
                    with: &decoder,
                    sequence: 1,
                    parameterSetRevision: 1,
                    bytes: &bytes,
                    mutate: mutation.apply
                )
            }
        }

        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        var bytes = Data([0, 0, 0, 2, 0x02, 0x01])
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try decodeAccessUnit(
                with: &decoder,
                sequence: 1,
                parameterSetRevision: 1,
                bytes: &bytes,
                mutate: {
                    $0.geometry.orientation = DH_ORIENTATION_FACE_UP
                    $0.geometry.non_flat_orientation =
                        DH_ORIENTATION_FACE_DOWN
                }
            )
        }
    }

    @Test("every discontinuity reason is preserved and unknown values fail")
    func discontinuityReasons() throws {
        let reasons: [
            (DhVideoDiscontinuity, DeviceHubNativeVideoDiscontinuityReason)
        ] = [
            (
                DH_VIDEO_DISCONTINUITY_SEQUENCE_GAP,
                .sequenceGap
            ),
            (
                DH_VIDEO_DISCONTINUITY_TIMESTAMP_CHANGED_WITHOUT_MARKER,
                .timestampChangedWithoutMarker
            ),
            (
                DH_VIDEO_DISCONTINUITY_MALFORMED_PAYLOAD,
                .malformedPayload
            ),
            (DH_VIDEO_DISCONTINUITY_NAL_TOO_LARGE, .nalTooLarge),
            (
                DH_VIDEO_DISCONTINUITY_PARAMETER_SET_TOO_LARGE,
                .parameterSetTooLarge
            ),
            (
                DH_VIDEO_DISCONTINUITY_ACCESS_UNIT_TOO_LARGE,
                .accessUnitTooLarge
            ),
            (
                DH_VIDEO_DISCONTINUITY_TOO_MANY_NAL_UNITS,
                .tooManyNALUnits
            ),
            (
                DH_VIDEO_DISCONTINUITY_MISSING_PARAMETER_SETS,
                .missingParameterSets
            ),
            (
                DH_VIDEO_DISCONTINUITY_UNEXPECTED_STREAM,
                .unexpectedStream
            )
        ]

        for (index, reason) in reasons.enumerated() {
            var decoder = DeviceHubNativeMediaEventDecoder(
                generation: generation
            )
            #expect(
                try decodeDiscontinuity(
                    with: &decoder,
                    sequence: 1,
                    reason: reason.0
                ) == .discontinuity(
                    DeviceHubNativeVideoDiscontinuity(
                        sequenceNumber: 1,
                        reason: reason.1
                    )
                ),
                "Failed reason at index \(index)"
            )
        }

        var decoder = DeviceHubNativeMediaEventDecoder(
            generation: generation
        )
        #expect(
            throws: DeviceHubNativeMediaEventDecodingError.invalidPayload
        ) {
            try withMediaEvent(
                kind: DH_EVENT_VIDEO_DISCONTINUITY,
                value: UInt64.max
            ) {
                try decoder.decodeMedia($0)
            }
        }
    }

    @Test("errors expose only a bounded sanitized category")
    func sanitizedErrors() {
        let error = DeviceHubNativeMediaEventDecodingError.invalidPayload

        #expect(
            error.description
                == "<redacted-native-media-decoding-error invalid-payload>"
        )
        #expect(error.debugDescription == error.description)
        #expect(
            error.customMirror.children.map(\.label) == ["failure"]
        )
        #expect(
            error.customMirror.children.first?.value as? String
                == error.description
        )
    }
}

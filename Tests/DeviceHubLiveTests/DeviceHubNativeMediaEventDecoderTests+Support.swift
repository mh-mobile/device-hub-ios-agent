import DeviceHubCore
import DeviceHubFFI
@testable import DeviceHubLive
import DeviceHubTransport
import Foundation
import Testing

extension DeviceHubNativeMediaEventDecoderTests {
    func decodeDatagram(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        sourcePort: UInt16 = 50001,
        bytes: inout Data,
        nativeBytes: DhBytes? = nil,
        mutate: (inout DhVideoDatagram) -> Void = { _ in }
    ) throws -> DeviceHubNativeMediaEvent {
        try bytes.withUnsafeBytes { buffer in
            var datagram = DhVideoDatagram()
            datagram.bytes =
                nativeBytes
                    ?? DhBytes(
                        data: buffer.baseAddress?.assumingMemoryBound(
                            to: UInt8.self
                        ),
                        count: buffer.count
                    )
            datagram.source_port = sourcePort
            mutate(&datagram)
            return try withUnsafePointer(to: &datagram) { pointer in
                try withMediaEvent(
                    sequence: sequence,
                    kind: DH_EVENT_VIDEO_DATAGRAM,
                    mutate: { $0.video_datagram = pointer },
                    operation: {
                        try decoder.decodeMedia($0)
                    }
                )
            }
        }
    }

    func decodeConfiguration(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        revision: UInt64,
        eventValue: UInt64? = nil,
        parameterSets: inout ParameterSets,
        overrideVideoBytes: DhBytes? = nil,
        mutate: (inout DhVideoConfiguration) -> Void = { _ in }
    ) throws -> DeviceHubNativeMediaEvent {
        try parameterSets.video.withUnsafeBytes { videoBuffer in
            try parameterSets.sequence.withUnsafeBytes { sequenceBuffer in
                try parameterSets.picture.withUnsafeBytes { pictureBuffer in
                    var configuration = DhVideoConfiguration()
                    configuration.revision = revision
                    configuration.pixel_width = 1290
                    configuration.pixel_height = 2796
                    configuration.orientation = DH_ORIENTATION_PORTRAIT
                    configuration.video_parameter_set =
                        overrideVideoBytes
                            ?? nativeBytes(videoBuffer)
                    configuration.sequence_parameter_set = nativeBytes(
                        sequenceBuffer
                    )
                    configuration.picture_parameter_set = nativeBytes(
                        pictureBuffer
                    )
                    mutate(&configuration)
                    return try withUnsafePointer(
                        to: &configuration
                    ) { pointer in
                        try withMediaEvent(
                            sequence: sequence,
                            kind: DH_EVENT_VIDEO_CONFIGURATION,
                            value: eventValue ?? revision,
                            mutate: {
                                $0.video_configuration = pointer
                            },
                            operation: {
                                try decoder.decodeMedia($0)
                            }
                        )
                    }
                }
            }
        }
    }

    func decodeAccessUnit(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        parameterSetRevision: UInt64,
        eventValue: UInt64? = nil,
        bytes: inout Data,
        nativeBytes: DhBytes? = nil,
        mutate: (inout DhVideoAccessUnit) -> Void = { _ in }
    ) throws -> DeviceHubNativeMediaEvent {
        try bytes.withUnsafeBytes { buffer in
            var accessUnit = DhVideoAccessUnit()
            accessUnit.bytes = nativeBytes ?? self.nativeBytes(buffer)
            accessUnit.parameter_set_revision = parameterSetRevision
            accessUnit.ssrc = 0x1234_5678
            accessUnit.rtp_timestamp = 0x9ABC_DEF0
            accessUnit.first_sequence_number = 65534
            accessUnit.last_sequence_number = 1
            accessUnit.is_sync = 1
            accessUnit.geometry = geometry()
            mutate(&accessUnit)
            return try withUnsafePointer(to: &accessUnit) { pointer in
                try withMediaEvent(
                    sequence: sequence,
                    kind: DH_EVENT_VIDEO_ACCESS_UNIT,
                    value: eventValue ?? parameterSetRevision,
                    mutate: { $0.video_access_unit = pointer },
                    operation: {
                        try decoder.decodeMedia($0)
                    }
                )
            }
        }
    }

    func decodeDiscontinuity(
        with decoder: inout DeviceHubNativeMediaEventDecoder,
        sequence: UInt64,
        reason: DhVideoDiscontinuity
    ) throws -> DeviceHubNativeMediaEvent {
        try withMediaEvent(
            sequence: sequence,
            kind: DH_EVENT_VIDEO_DISCONTINUITY,
            value: UInt64(reason)
        ) {
            try decoder.decodeMedia($0)
        }
    }

    func withMediaEvent<Result>(
        sequence: UInt64 = 1,
        kind: DhEventKind,
        value: UInt64 = 0,
        generation: DhGeneration? = nil,
        mutate: (inout DhEvent) -> Void = { _ in },
        operation: (UnsafePointer<DhEvent>) throws -> Result
    ) rethrows -> Result {
        let nativeGeneration = DeviceHubNativeGeneration(
            self.generation.rawValue
        )
        var event = DhEvent()
        event.struct_size = UInt32(MemoryLayout<DhEvent>.size)
        event.abi_version = DeviceHubNativeABI.expectedVersion
        event.generation =
            generation
                ?? DhGeneration(
                    high: nativeGeneration.high,
                    low: nativeGeneration.low
                )
        event.sequence = sequence
        event.kind = kind
        event.state = DH_SESSION_STATE_CONNECTED
        event.phase = DH_CONNECTION_PHASE_STREAMING
        event.value = value
        mutate(&event)
        return try withUnsafePointer(to: &event, operation)
    }

    func nativeBytes(
        _ buffer: UnsafeRawBufferPointer
    ) -> DhBytes {
        DhBytes(
            data: buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
            count: buffer.count
        )
    }

    func geometry() -> DhDisplayGeometry {
        var geometry = DhDisplayGeometry()
        geometry.pixel_width = 2796
        geometry.pixel_height = 1290
        geometry.orientation = DH_ORIENTATION_LANDSCAPE_LEFT
        geometry.non_flat_orientation = DH_ORIENTATION_LANDSCAPE_LEFT
        return geometry
    }
}

struct ParameterSets {
    var video = Data([0x40, 0x01])
    var sequence = Data([0x42, 0x01])
    var picture = Data([0x44, 0x01])
}

enum ConfigurationMutation {
    case orientation(DhOrientation)
    case pixelHeight(UInt32)
    case pixelWidth(UInt32)
    case reserved
    case revision(UInt64)

    func apply(to configuration: inout DhVideoConfiguration) {
        switch self {
        case let .orientation(value):
            configuration.orientation = value
        case let .pixelHeight(value):
            configuration.pixel_height = value
        case let .pixelWidth(value):
            configuration.pixel_width = value
        case .reserved:
            configuration.reserved = 1
        case let .revision(value):
            configuration.revision = value
        }
    }
}

enum AccessUnitMutation {
    case fallback(DhOrientation)
    case geometryReserved
    case isSync(UInt8)
    case orientation(DhOrientation)
    case orientationLocked(UInt8)
    case pixelHeight(UInt32)
    case pixelWidth(UInt32)
    case reserved
    case revision(UInt64)

    func apply(to accessUnit: inout DhVideoAccessUnit) {
        switch self {
        case let .fallback(value):
            accessUnit.geometry.non_flat_orientation = value
        case .geometryReserved:
            accessUnit.geometry.reserved.0 = 1
        case let .isSync(value):
            accessUnit.is_sync = value
        case let .orientation(value):
            accessUnit.geometry.orientation = value
        case let .orientationLocked(value):
            accessUnit.geometry.orientation_locked = value
        case let .pixelHeight(value):
            accessUnit.geometry.pixel_height = value
        case let .pixelWidth(value):
            accessUnit.geometry.pixel_width = value
        case .reserved:
            accessUnit.reserved.0 = 1
        case let .revision(value):
            accessUnit.parameter_set_revision = value
        }
    }
}

import DeviceHubCore
import DeviceHubPersistence

extension TargetPairingRecord {
    func deviceSummary(
        reachability: DeviceReachability
    ) -> DeviceSummary {
        DeviceSummary(
            id: deviceID,
            name: displayName,
            productType: productType,
            operatingSystemVersion: operatingSystemVersion,
            pairingState: .paired,
            reachability: reachability
        )
    }
}

extension NativeConnectionPhase {
    var connectionPhase: ConnectionPhase? {
        switch self {
        case .idle:
            .locating
        case .verifyingPairing:
            .verifyingPairing
        case .openingTunnel:
            .openingTunnel
        case .discoveringServices:
            .discoveringServices
        case .capturingScreenshot:
            .capturingScreenshot
        case .preparingDevice:
            .preparingDeveloperServices
        case .openingInput,
             .startingDisplayStream,
             .waitingForVideoReceiver:
            .startingDisplay
        case .ready, .streaming:
            .ready
        case .awaitingPairingPeer,
             .bindingPairingListener,
             .pairing,
             .persistingPairRecord:
            nil
        }
    }
}

/// Classifies a native failure by what the user can do about it.
///
/// The code names the operation; `stage` and `retryable` say whether the
/// device refused us or simply could not be reached. A transport failure must
/// never be reported as a changed identity (which sends the user to re-pair),
/// and a retryable failure without a specific meaning is a lost connection:
/// before a session exists that reads as offline.
func mapNativeFailure(
    _ failure: NativeSessionFailure
) -> DeviceHubError {
    switch failure.code {
    case "pair_verify_failed":
        switch failure.stage {
        case "pair_verify_timeout", "pair_verify_transport":
            return .deviceOffline
        case "pair_verify_peer_rejection":
            return .needsPairing
        default:
            return .peerAuthenticationFailed
        }
    case "bonjour_authentication_failed":
        return .peerAuthenticationFailed
    case "remote_pairing_connect_failed":
        return .deviceOffline
    case "developer_mode_disabled":
        return .developerModeDisabled
    case "developer_image_unavailable":
        return .developerImageUnavailable
    case "developer_image_incompatible":
        return .developerImageIncompatible
    case "developer_image_lookup_presence_malformed",
         "developer_image_lookup_signature_array_malformed",
         "developer_image_lookup_signature_array_empty",
         "developer_image_lookup_signature_empty",
         "developer_image_lookup_signature_malformed",
         "developer_image_lookup_signature_missing",
         "developer_image_lookup_signature_type_unsupported",
         "developer_image_lookup_unsupported",
         "developer_mode_status_unsupported",
         "unsupported_protocol_version",
         "video_negotiation_rejected":
        return .unsupportedProtocolVersion
    case "media_stalled":
        return .mediaStalled
    case "pair_setup_failed":
        return .pairingRejected
    case "pairing_listener_accept_failed":
        return .pairingTimedOut
    case "video_configuration_missing",
         "video_datagram_rejected",
         "video_receiver_rejected",
         "video_stream_failed":
        return .decoderFailed
    case "invalid_argument",
         "invalid_rsd_metadata",
         "invalid_screenshot_png":
        return .malformedDeviceAnnouncement
    default:
        guard failure.retryable else {
            return .secureConnectionFailed
        }
        return preSessionStages.contains(failure.stage)
            ? .deviceOffline
            : .connectionLost
    }
}

/// Stages that run before a session exists: failing here means the device
/// could not be reached rather than that an established session was lost.
private let preSessionStages: Set<String> = [
    "bonjour_authentication",
    "cd_tunnel",
    "developer_readiness",
    "pair_verify",
    "pair_verify_timeout",
    "pair_verify_transport",
    "rsd_handshake",
    "tls_psk_tunnel",
    "tunnel_listener"
]

extension NativeVideoFailureReason {
    /// The user-facing error for a terminated native video stream.
    var deviceHubError: DeviceHubError {
        switch self {
        case let .native(failure):
            mapNativeFailure(failure)
        case .bufferSaturated:
            .mediaStalled
        case .invalidAccessUnit,
             .invalidConfiguration,
             .invalidSequence,
             .missingConfiguration,
             .multipleConsumers:
            .decoderFailed
        }
    }
}

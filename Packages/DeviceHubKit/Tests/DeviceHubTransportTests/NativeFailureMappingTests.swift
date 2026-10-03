import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Native failure classification")
struct NativeFailureMappingTests {
    private func map(_ code: String, _ stage: String, retryable: Bool) -> DeviceHubError {
        mapNativeFailure(NativeSessionFailure(code: code, stage: stage, retryable: retryable))
    }

    @Test("a Pair Verify that never completed is offline, not a changed identity")
    func pairVerifyTransportIsOffline() {
        #expect(map("pair_verify_failed", "pair_verify_timeout", retryable: true) == .deviceOffline)
        #expect(map("pair_verify_failed", "pair_verify_transport", retryable: true) == .deviceOffline)
        #expect(map("remote_pairing_connect_failed", "pair_verify", retryable: true) == .deviceOffline)
        #expect(map("remote_pairing_connect_failed", "session_lifecycle", retryable: true) == .deviceOffline)
    }

    @Test("a device that rejects our pairing needs pairing; a bad proof is an identity failure")
    func pairVerifyAuthenticationOutcomes() {
        #expect(map("pair_verify_failed", "pair_verify_peer_rejection", retryable: false) == .needsPairing)
        for stage in [
            "pair_verify_m2_authentication",
            "pair_verify_m2_decryption",
            "pair_verify_m2_identifier",
            "pair_verify_m2_shape",
            "pair_verify_m2_signature",
            "pair_verify_m4_completion",
            "pair_verify_protocol"
        ] {
            #expect(map("pair_verify_failed", stage, retryable: false) == .peerAuthenticationFailed, "\(stage)")
        }
    }

    @Test("retryable failures after the session started are a lost connection")
    func streamingTransportIsConnectionLost() {
        #expect(map("video_stream_receive_failed", "video_stream", retryable: true) == .connectionLost)
        #expect(map("video_stream_start_timed_out", "video_stream", retryable: true) == .connectionLost)
        #expect(map("rotation_failed", "rotation", retryable: true) == .connectionLost)
        #expect(map("tunnel_connect_failed", "tls_psk_tunnel", retryable: true) == .deviceOffline)
        #expect(map("rsd_handshake_failed", "rsd_handshake", retryable: true) == .deviceOffline)
    }

    @Test("decoder and version failures keep their specific meaning")
    func specificFailures() {
        #expect(map("video_datagram_rejected", "video_stream_payload_invalid", retryable: false) == .decoderFailed)
        #expect(map("video_configuration_missing", "video_stream", retryable: false) == .decoderFailed)
        #expect(map("media_stalled", "video_stream", retryable: true) == .mediaStalled)
        #expect(map("unsupported_protocol_version", "control_stream", retryable: false) == .unsupportedProtocolVersion)
        #expect(map("video_negotiation_rejected", "video_negotiation", retryable: false) == .unsupportedProtocolVersion)
    }

    @Test("video stream terminal reasons keep native and saturation causes")
    func videoFailureReasons() {
        let native = NativeSessionFailure(
            code: "video_stream_receive_failed",
            stage: "video_stream",
            retryable: true
        )
        #expect(NativeVideoFailureReason.native(native).deviceHubError == .connectionLost)
        #expect(NativeVideoFailureReason.bufferSaturated.deviceHubError == .mediaStalled)
        #expect(NativeVideoFailureReason.invalidAccessUnit.deviceHubError == .decoderFailed)
    }

    @Test("every failure code and stage the Rust protocol produces is accepted")
    func rustVocabularyIsAccepted() throws {
        let source = try FileManager.default
            .contentsOfDirectory(at: Self.rustSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "rs" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .map(Self.productionSource)
            .joined()
        let codes = try Self.captures(#"PublicFailure::new\(\s*"([a-z0-9_]+)""#, in: source)
        // Stages are passed either directly or through helpers that take a
        // `stage: &'static str` parameter (`enqueue_on`, `classify_hid_error`, …).
        var stages = try Self.captures(
            #"PublicFailure::new\(\s*"[a-z0-9_]+",\s*"([a-z0-9_]+)""#,
            in: source
        )
        let helpers = try Self.captures(
            #"fn (\w+)(?:<[^>]*>)?\([^)]*?\bstage: &'static str"#,
            in: source
        ).subtracting(["new"])
        for helper in helpers {
            for arguments in Self.callArguments(of: helper, in: source) {
                try stages.formUnion(Self.captures(#""([a-z0-9_]+)""#, in: String(arguments)))
            }
        }
        // Guards against the scan silently covering only part of the sources.
        #expect(codes.count > 70)
        #expect(stages.isSuperset(of: ["touch_input", "hardware_button_input", "input"]))
        for code in codes {
            let failure = NativeSessionFailure(code: code, stage: "control_stream", retryable: true)
            #expect(failure.code == code, "code \(code)")
        }
        for stage in stages {
            let failure = NativeSessionFailure(code: "invalid_state", stage: stage, retryable: true)
            #expect(failure.stage == stage, "stage \(stage)")
        }
    }

    private static func captures(_ pattern: String, in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
        return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The text between the parentheses of each call to `function`.
    private static func callArguments(of function: String, in text: String) -> [Substring] {
        var calls: [Substring] = []
        var searchStart = text.startIndex
        while let call = text.range(
            of: #"\b\#(function)\("#,
            options: .regularExpression,
            range: searchStart ..< text.endIndex
        ) {
            var depth = 1
            var end = call.upperBound
            while depth > 0, end < text.endIndex {
                if text[end] == "(" {
                    depth += 1
                }
                if text[end] == ")" {
                    depth -= 1
                }
                end = text.index(after: end)
            }
            calls.append(text[call.upperBound ..< end])
            searchStart = end
        }
        return calls
    }

    /// Drops each file's test module; test-only helpers elsewhere stay.
    private static func productionSource(_ file: String) -> String {
        guard let range = file.range(
            of: #"#\[cfg\(test\)\]\s*mod tests"#,
            options: .regularExpression
        ) else {
            return file
        }
        return String(file[..<range.lowerBound])
    }

    private static let rustSources = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../Rust/DeviceHubFFI/src")
        .standardizedFileURL
}

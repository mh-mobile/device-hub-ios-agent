import ComposableArchitecture
import CoreGraphics
import DeviceHubClient
import DeviceHubCore
@testable import DeviceHubFeature
import Foundation
import Testing

@Suite("Agent HTTP access policy")
struct AgentAccessPolicyTests {
    private let token = "0123456789abcdef0123456789abcdef"

    @Test("the API stays off without a long enough configured token")
    func missingTokenDisablesTheAPI() {
        #expect(AgentAccessPolicy(token: nil) == nil)
        #expect(AgentAccessPolicy(token: "") == nil)
        #expect(AgentAccessPolicy(token: "  ") == nil)
        #expect(AgentAccessPolicy(token: "short") == nil)
        #expect(AgentAccessPolicy(token: "$(DEVICE_HUB_AGENT_TOKEN)") == nil)
        #expect(AgentAccessPolicy(token: token) != nil)
    }

    @Test("only loopback and tailnet sources are accepted")
    func sourceAddresses() throws {
        let policy = try #require(AgentAccessPolicy(token: token))
        let header = "Bearer \(token)"

        for allowed in [
            [127, 0, 0, 1],
            [100, 64, 0, 1],
            [100, 127, 255, 254],
            ipv6("::1"),
            ipv6("::ffff:127.0.0.1"),
            ipv6("::ffff:100.100.1.2"),
            ipv6("fd7a:115c:a1e0::1")
        ] as [[UInt8]] {
            #expect(
                policy.decide(sourceAddress: allowed, authorization: header)
                    == .allowed,
                "\(allowed)"
            )
        }
        for denied in [
            [192, 168, 1, 10],
            [10, 0, 0, 5],
            [100, 63, 255, 255],
            [100, 128, 0, 0],
            ipv6("fe80::1"),
            ipv6("::ffff:192.168.1.10"),
            ipv6("fd7a:115c:a1e1::1"),
            []
        ] as [[UInt8]] {
            #expect(
                policy.decide(sourceAddress: denied, authorization: header)
                    == .forbiddenSource,
                "\(denied)"
            )
        }
    }

    @Test("requests need the exact bearer token")
    func bearerToken() throws {
        let policy = try #require(AgentAccessPolicy(token: token))
        let loopback: [UInt8] = [127, 0, 0, 1]

        #expect(policy.decide(sourceAddress: loopback, authorization: nil) == .unauthorized)
        #expect(policy.decide(sourceAddress: loopback, authorization: token) == .unauthorized)
        #expect(
            policy.decide(sourceAddress: loopback, authorization: "Bearer \(token)x")
                == .unauthorized
        )
        #expect(
            policy.decide(sourceAddress: loopback, authorization: "Bearer wrong")
                == .unauthorized
        )
        #expect(
            policy.decide(sourceAddress: loopback, authorization: "bearer \(token)")
                == .allowed
        )
    }

    private func ipv6(_ text: String) -> [UInt8] {
        var address = in6_addr()
        precondition(inet_pton(AF_INET6, text, &address) == 1)
        return withUnsafeBytes(of: address) { Array($0) }
    }
}

@Suite("Agent HTTP request parsing")
struct AgentHTTPRequestTests {
    @Test("a complete request exposes method, path, headers, and JSON body")
    func completeRequest() {
        let raw = Data(
            "POST /tap?x=1 HTTP/1.1\r\nAuthorization: Bearer t\r\n"
                .utf8
        ) + Data("Content-Length: 15\r\n\r\n{\"x\":1,\"y\":2.5}".utf8)

        guard case let .complete(request) = AgentHTTPRequest.parse(raw) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/tap")
        #expect(request.header("authorization") == "Bearer t")
        #expect(request.number("x") == 1)
        #expect(request.number("y") == 2.5)
    }

    @Test("a header with an empty value is valid, a line without a colon is not")
    func emptyHeaderValue() {
        let raw = Data("GET /screen HTTP/1.1\r\nX-Empty:\r\nAuthorization: Bearer t\r\n\r\n".utf8)

        guard case let .complete(request) = AgentHTTPRequest.parse(raw) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(request.header("x-empty") == "")
        #expect(request.header("authorization") == "Bearer t")
        #expect(
            AgentHTTPRequest.parse(Data("GET / HTTP/1.1\r\nNoColon\r\n\r\n".utf8))
                == .malformed
        )
    }

    @Test("partial input waits and oversized or malformed input is rejected")
    func incompleteAndMalformed() {
        #expect(AgentHTTPRequest.parse(Data("GET / HTTP/1.1\r\n".utf8)) == .incomplete)
        #expect(
            AgentHTTPRequest.parse(
                Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8)
            ) == .incomplete
        )
        #expect(
            AgentHTTPRequest.parse(
                Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
            ) == .malformed
        )
        #expect(
            AgentHTTPRequest.parse(
                Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)
            ) == .malformed
        )
        #expect(
            AgentHTTPRequest.parse(
                Data(repeating: UInt8(ascii: "a"), count: AgentHTTPRequest.maximumHeadBytes + 1)
            ) == .malformed
        )
        #expect(AgentHTTPRequest.parse(Data("BROKEN\r\n\r\n".utf8)) == .malformed)
    }
}

@Suite("Agent drag timing")
struct AgentDragTimingTests {
    @Test("duration is finite and bounded so the step sleep cannot trap")
    func durationBounds() throws {
        #expect(try AgentBridge.dragStepDuration(total: 0.3, steps: 12) == .milliseconds(25))
        #expect(try AgentBridge.dragStepDuration(total: 0, steps: 12) == .zero)
        #expect(throws: AgentBridgeError.self) {
            try AgentBridge.dragStepDuration(total: 1e30, steps: 12)
        }
        #expect(throws: AgentBridgeError.self) {
            try AgentBridge.dragStepDuration(total: -1, steps: 12)
        }
        #expect(throws: AgentBridgeError.self) {
            try AgentBridge.dragStepDuration(total: .nan, steps: 12)
        }
        #expect(throws: AgentBridgeError.self) {
            try AgentBridge.dragStepDuration(total: .infinity, steps: 12)
        }
    }
}

@Suite("Agent drag cleanup")
struct AgentDragCleanupTests {
    @Test("a drag that fails midway lifts the finger instead of leaving it down")
    func failedDragCancelsTheTouch() async throws {
        let recorded = LockIsolated<[DeviceCommand]>([])
        let target = device(id: "agent", name: "Test iPhone")
        let session = DeviceSession(
            id: DeviceSessionID(rawValue: fixtureUUID(95)),
            device: target,
            events: AsyncThrowingStream { $0.finish() },
            frames: AsyncStream { $0.finish() },
            command: { command in
                recorded.withValue { $0.append(command) }
                if recorded.value.count == 3 {
                    throw DeviceHubError.connectionLost
                }
            },
            disconnect: {}
        )
        let bridge = try await grantedBridge(
            session: session,
            frame: remoteFrame(
                generation: SessionGeneration(rawValue: fixtureUUID(96)),
                receivedAt: Date(timeIntervalSince1970: 0),
                sequenceNumber: 1
            )
        )

        await #expect(throws: DeviceHubError.self) {
            try await bridge.drag(from: (0, 0), to: (1, 1), duration: 0, steps: 4)
        }

        let phases = recorded.value.compactMap { command -> TouchPhase? in
            guard case let .touch(touch) = command else {
                return nil
            }
            return touch.phase
        }
        #expect(phases.first == .began)
        #expect(phases.last == .cancelled)
    }
}

@Suite("Agent coordinates")
struct AgentCoordinateTests {
    @Test("a point in a landscape screenshot is sent in native portrait pixels")
    func landscapePointsAreRotated() async throws {
        let recorded = LockIsolated<[DeviceCommand]>([])
        let bridge = try await agentBridge(
            nativePixels: PixelSize(width: 100, height: 200),
            orientation: .landscapeLeft,
            imageWidth: 200,
            imageHeight: 100,
            recorded: recorded
        )

        try await bridge.tap(x: 0, y: 0)

        #expect(recorded.value == [.tap(TargetPixelPoint(x: 99, y: 0))])
    }

    @Test("a point outside the screenshot is rejected, not clamped")
    func outsidePointsAreRejected() async throws {
        let recorded = LockIsolated<[DeviceCommand]>([])
        let bridge = try await agentBridge(
            nativePixels: PixelSize(width: 100, height: 200),
            orientation: .portrait,
            imageWidth: 100,
            imageHeight: 200,
            recorded: recorded
        )

        await #expect(throws: AgentBridgeError.self) {
            try await bridge.tap(x: 150, y: 10)
        }
        #expect(recorded.value.isEmpty)
    }

    private func agentBridge(
        nativePixels: PixelSize,
        orientation: ScreenOrientation,
        imageWidth: Int,
        imageHeight: Int,
        recorded: LockIsolated<[DeviceCommand]>
    ) async throws -> AgentBridge {
        let context = try #require(CGContext(
            data: nil,
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bytesPerRow: imageWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let frame = try RemoteDisplayFrame(
            metadata: .videoFrame(FrameMetadata(
                generation: SessionGeneration(rawValue: fixtureUUID(97)),
                sequenceNumber: 1,
                receivedAt: Date(timeIntervalSince1970: 0),
                pixelSize: nativePixels,
                orientation: orientation
            )),
            image: #require(context.makeImage())
        )
        let session = DeviceSession(
            id: DeviceSessionID(rawValue: fixtureUUID(98)),
            device: device(id: "agent", name: "Test iPhone"),
            events: AsyncThrowingStream { $0.finish() },
            frames: AsyncStream { $0.finish() },
            command: { command in recorded.withValue { $0.append(command) } },
            disconnect: {}
        )
        return try await grantedBridge(session: session, frame: frame)
    }
}

/// A bridge granted `frame` of `session`, which a coordinator owns, as the
/// session feature grants it while the app accepts input.
func grantedBridge(session: DeviceSession, frame: RemoteDisplayFrame) async throws -> AgentBridge {
    let coordinator = DeviceSessionCoordinator()
    var client = DeviceHubClient.testValue
    client.connect = { _ in session }
    let attemptID = fixtureUUID(97)
    _ = try await coordinator.replace(attemptID: attemptID, deviceID: session.device.id, using: client)
    let bridge = AgentBridge()
    bridge.set(AgentBridge.Grant(
        attemptID: attemptID,
        sessionID: session.id,
        frame: frame,
        coordinator: coordinator
    ))
    return bridge
}

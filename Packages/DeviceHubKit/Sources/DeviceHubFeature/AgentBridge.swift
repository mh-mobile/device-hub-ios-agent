import CoreGraphics
import DeviceHubClient
import DeviceHubCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The live session and its latest frame, for an agent driving the device over HTTP.
///
/// Commands go straight to the session, beside the canvas's own input path: this is
/// a prototype for agents, not part of the app's authorization model.
public final class AgentBridge: @unchecked Sendable {
    public static let shared = AgentBridge()

    private let lock = NSLock()
    private var session: DeviceSession?
    private var frame: RemoteDisplayFrame?

    func update(session: DeviceSession, frame: RemoteDisplayFrame) {
        lock.withLock {
            self.session = session
            self.frame = frame
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noSession
        public var description: String {
            "no device is being shown; open one in Device Hub first"
        }
    }

    /// Target pixel size of the latest frame: the coordinate space for every command.
    public func screenSize() throws -> (width: Int, height: Int) {
        guard let frame = lock.withLock({ frame }) else { throw Failure.noSession }
        return (frame.image.width, frame.image.height)
    }

    public func screenshotPNG() throws -> Data {
        guard let frame = lock.withLock({ frame }) else { throw Failure.noSession }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, frame.image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    public func tap(x: Double, y: Double) async throws {
        try await send(.tap(TargetPixelPoint(x: x, y: y)))
    }

    /// The longest drag an agent may request.
    static let maximumDragDuration = 10.0

    /// A one-finger drag from start to end in `steps` moves over `duration` seconds.
    public func drag(from start: (Double, Double), to end: (Double, Double), duration: Double = 0.3, steps: Int = 12) async throws {
        let steps = max(steps, 1)
        let stepDuration = try Self.dragStepDuration(total: duration, steps: steps)
        let point = { (t: Double) in
            TargetPixelPoint(x: start.0 + (end.0 - start.0) * t, y: start.1 + (end.1 - start.1) * t)
        }
        try await send(.touch(TouchCommand(contactID: 0, point: point(0), phase: .began)))
        for step in 1 ... steps {
            try await Task.sleep(for: stepDuration)
            try await send(.touch(TouchCommand(contactID: 0, point: point(Double(step) / Double(steps)), phase: .moved)))
        }
        try await send(.touch(TouchCommand(contactID: 0, point: point(1), phase: .ended)))
    }

    /// Rejects a duration outside `0...maximumDragDuration` (including NaN and
    /// infinity) before it reaches `Duration`, which traps on huge values.
    static func dragStepDuration(total: Double, steps: Int) throws -> Duration {
        guard total.isFinite, (0 ... maximumDragDuration).contains(total) else {
            throw AgentBridgeError("duration must be between 0 and \(maximumDragDuration) seconds")
        }
        return .milliseconds((total * 1000 / Double(max(steps, 1))).rounded())
    }

    public func type(_ text: String) async throws {
        for character in text {
            let key: DeviceKey = switch character {
            case " ": .space
            case "\n": .return
            case "\t": .tab
            default: .character(character)
            }
            try await send(.keyTap(key, modifiers: []))
        }
    }

    public func press(_ name: String) async throws {
        let button: DeviceButton? = switch name {
        case "home": .home
        case "lock": .lock
        case "mute": .mute
        case "siri": .siri
        case "volumeDown": .volumeDown
        case "volumeUp": .volumeUp
        default: nil
        }
        guard let button else { throw AgentBridgeError("unknown button \(name)") }
        try await send(.buttonTap(button))
    }

    private func send(_ command: DeviceCommand) async throws {
        guard let session = lock.withLock({ session }) else { throw Failure.noSession }
        try await session.command(command)
    }
}

public struct AgentBridgeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) {
        self.description = description
    }
}

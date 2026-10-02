import ComposableArchitecture
import DeviceHubClient
import Foundation

/// Screen-first product logic for discovering, pairing, viewing, and
/// controlling exactly one nearby device.
@Reducer
public struct RemoteSessionFeature {
    enum CancelID {
        case availability
        case availabilityRestart
        case commands
        case connect
        case frames
        case lifecycle
        case reconnect
        case rosterLoad
    }

    /// Wait before restarting discovery that ended or reconnecting a session
    /// that failed with an automatically retryable error.
    ///
    /// ponytail: fixed delay; a device that keeps failing is retried every
    /// few seconds. Switch to exponential backoff if that ever costs battery.
    public static let recoveryDelay: Duration = .seconds(3)

    @Dependency(\.backgroundExecution) var backgroundExecution
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.deviceHub) var deviceHub
    @Dependency(\.uuid) var uuid

    let sessionCoordinator: DeviceSessionCoordinator

    public init() {
        sessionCoordinator = DeviceSessionCoordinator()
    }

    public var body: some ReducerOf<Self> {
        CombineReducers {
            Reduce(reduceLifecycle)
            Reduce(reduceSelection)
            Reduce(reducePresentation)
            Reduce(reduceConnection)
            Reduce(reduceMedia)
            Reduce(reduceInput)
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}

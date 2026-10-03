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

    /// Wait before restarting discovery that ended, and before the first
    /// automatic reconnect; each further reconnect waits twice as long.
    public static let recoveryDelay: Duration = .seconds(3)

    /// Automatic reconnects in a row before the app waits for the user. A
    /// failure that repeats deterministically stops after about 90 seconds
    /// instead of reconnecting forever; a live frame starts the count over.
    public static let maximumReconnectAttempts = 5

    @Dependency(\.agentBridge) var agentBridge
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
        // The agent may act only while the app itself accepts input.
        .onChange(of: \.agentGrantKey) { _, _ in
            Reduce { state, _ in
                grantAgent(state: state)
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}

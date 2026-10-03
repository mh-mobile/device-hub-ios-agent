import ComposableArchitecture
import DeviceHubClient
import DeviceHubCore
import Foundation

extension RemoteSessionFeature {
    func reduceConnection(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case let .connectionResponse(attemptID, deviceID, result):
            return handleConnectionResponse(
                state: &state,
                attemptID: attemptID,
                deviceID: deviceID,
                result: result
            )

        case let .sessionEventsFinished(attemptID, sessionID):
            guard var session = state.session,
                  session.attemptID == attemptID,
                  session.sessionID == sessionID
            else {
                return .none
            }
            DeviceHubFeatureTrace.emit("session_events_finished")
            if case .ended = session.remoteState?.connection {
                return .none
            }
            // Close the original session ID: a cleanup failure for it no
            // longer matches the ended state, so it cannot replace the error
            // that ended the session.
            let ending = session
            session.connectionError = .connectionLost
            session.sessionID = nil
            state.activeContactIDs.removeAll()
            state.remediation = DeviceHubRemediation(
                error: .connectionLost
            )
            state.session = session
            return .concatenate(
                cancelSessionEffects(),
                .merge(
                    closeSessionEffect(session: ending),
                    reconnectEffect(
                        attemptID: attemptID,
                        after: .connectionLost,
                        state: state
                    )
                )
            )

        case let .sessionStreamFailed(attemptID, sessionID, error):
            guard var session = state.session,
                  session.attemptID == attemptID,
                  session.sessionID == sessionID
            else {
                return .none
            }
            DeviceHubFeatureTrace.emit(
                "session_stream_failed error=\(String(describing: error))"
            )
            let ending = session
            session.connectionError = error
            session.sessionID = nil
            state.activeContactIDs.removeAll()
            state.remediation = DeviceHubRemediation(error: error)
            state.session = session
            return .concatenate(
                cancelSessionEffects(),
                .merge(
                    closeSessionEffect(session: ending),
                    reconnectEffect(attemptID: attemptID, after: error, state: state)
                )
            )

        case let .sessionUpdateReceived(attemptID, sessionID, update):
            return handleSessionUpdate(
                state: &state,
                attemptID: attemptID,
                sessionID: sessionID,
                update: update
            )

        default:
            return .none
        }
    }

    private func handleConnectionResponse(
        state: inout State,
        attemptID: UUID,
        deviceID: DeviceID,
        result: Result<DeviceSession, DeviceHubError>
    ) -> Effect<Action> {
        guard var session = state.session,
              session.attemptID == attemptID,
              session.device.id == deviceID
        else {
            if case let .success(staleSession) = result {
                let sessionCoordinator = sessionCoordinator
                return .run { send in
                    guard let error = await sessionCoordinator.close(
                        attemptID: attemptID
                    ) else {
                        return
                    }
                    await send(
                        .inputCleanupFailed(
                            attemptID: attemptID,
                            sessionID: staleSession.id,
                            error: error
                        )
                    )
                }
            }
            return .none
        }

        switch result {
        case let .failure(error):
            DeviceHubFeatureTrace.emit(
                "connection_failed error=\(String(describing: error))"
            )
            session.connectionError = error
            session.remoteState = nil
            session.sessionID = nil
            state.remediation = DeviceHubRemediation(error: error)
            state.session = session
            return reconnectEffect(attemptID: attemptID, after: error, state: state)

        case let .success(openedSession):
            DeviceHubFeatureTrace.emit("connection_opened")
            session.connectionError = nil
            session.device = openedSession.device
            session.remoteState = nil
            session.sessionID = openedSession.id
            state.remediation = nil
            state.session = session
            return observe(
                attemptID: attemptID,
                session: openedSession
            )
        }
    }

    private func handleSessionUpdate(
        state: inout State,
        attemptID: UUID,
        sessionID: DeviceSessionID,
        update: SessionUpdate
    ) -> Effect<Action> {
        guard var session = state.session,
              session.attemptID == attemptID,
              session.sessionID == sessionID
        else {
            return .none
        }

        let wasAcceptingInput = session.acceptsInput
        var remoteState = session.remoteState
            ?? RemoteSessionState(
                deviceID: session.device.id,
                generation: update.generation,
                reachability: session.device.reachability
            )
        guard remoteState.apply(update) == .accepted else {
            return .none
        }

        session.remoteState = remoteState
        updateState(
            state: &state,
            session: &session,
            event: update.event
        )
        state.session = session

        if update.event.endsSession {
            state.session?.sessionID = nil
            state.activeContactIDs.removeAll()
            return .concatenate(
                cancelSessionEffects(),
                .merge(
                    closeSessionEffect(session: session),
                    reconnectEffect(
                        attemptID: session.attemptID,
                        after: session.connectionError,
                        state: state
                    )
                )
            )
        }
        guard wasAcceptingInput, !session.acceptsInput else {
            return .none
        }
        DeviceHubFeatureTrace.emit(
            "input_revoked source=session_update "
                + "event=\(update.event.inputRevocationTraceKind)"
        )
        return .concatenate(
            revokeInput(state: &state),
            .cancel(id: CancelID.commands)
        )
    }

    private func updateState(
        state: inout State,
        session: inout ActiveRemoteSession,
        event: DeviceSessionEvent
    ) {
        switch event {
        case let .deviceInfoUpdated(device):
            session.device = device
            state.replaceRosterDevice(device)

        case let .ended(error):
            session.connectionError = error
            state.activeContactIDs.removeAll()
            if let error {
                state.remediation = DeviceHubRemediation(error: error)
            }

        case .reconnected:
            session.connectionError = nil
            session.frame = nil
            session.revokedInputMetadata = nil

        case .displayReady,
             .hidReadinessChanged,
             .phaseChanged,
             .reachabilityChanged:
            break

        case .screenshot, .videoFrame:
            session.connectionError = nil
            session.evaluatedAt = date.now
            state.remediation = nil
        }
    }
}

private extension DeviceSessionEvent {
    var inputRevocationTraceKind: String {
        switch self {
        case .phaseChanged:
            "phase_changed"
        case .deviceInfoUpdated:
            "device_info_updated"
        case .screenshot:
            "screenshot"
        case .displayReady:
            "display_ready"
        case .videoFrame:
            "video_frame"
        case .hidReadinessChanged:
            "hid_readiness_changed"
        case .reachabilityChanged:
            "reachability_changed"
        case .reconnected:
            "reconnected"
        case .ended:
            "ended"
        }
    }
}

import ComposableArchitecture
import DeviceHubCore

extension RemoteSessionFeature {
    func reduceSelection(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case let .availabilitySnapshotReceived(devices):
            return reconcileRoster(
                state: &state,
                devices: devices
            )

        case let .deviceSelected(deviceID):
            guard deviceID != state.selectedDeviceID
                || state.session?.device.id != deviceID
            else {
                return .none
            }
            guard let device = state.roster.devices.first(
                where: { $0.id == deviceID }
            ) else {
                return .none
            }

            state.selectedDeviceID = deviceID
            state.isViewingStopped = false
            state.pairing = nil
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case let .pairedDevicesResponse(result):
            state.isLoadingRoster = false
            switch result {
            case let .success(devices):
                return reconcileRoster(
                    state: &state,
                    devices: devices
                )
            case let .failure(error):
                state.remediation = DeviceHubRemediation(error: error)
                return .none
            }

        case let .reconnectTimerFired(attemptID):
            guard state.lifecycle != .inactive else {
                // A notification or Slide Over made the app briefly
                // inactive; try again later instead of dropping the retry.
                guard let session = state.session,
                      session.attemptID == attemptID
                else {
                    return .none
                }
                return reconnectEffect(
                    attemptID: attemptID,
                    after: session.connectionError
                )
            }
            guard state.lifecycle == .active,
                  !state.isViewingStopped,
                  let session = state.session,
                  session.attemptID == attemptID,
                  session.sessionID == nil,
                  session.connectionError != nil,
                  let device = state.selectedDevice,
                  device.id == session.device.id
            else {
                return .none
            }
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case .retrySelectedDevice:
            guard let device = state.selectedDevice else {
                return .none
            }
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case .startViewingButtonTapped:
            guard let device = state.selectedDevice else {
                return .none
            }
            state.isViewingStopped = false
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case .stopViewingButtonTapped:
            guard state.selectedDevice != nil else {
                return .none
            }
            let previousSession = state.session
            state.activeContactIDs.removeAll()
            state.isViewingStopped = true
            state.session = nil
            guard let previousSession else {
                return cancelSessionEffects()
            }
            return .concatenate(
                cancelSessionEffects(),
                closeSessionEffect(session: previousSession)
            )

        default:
            return .none
        }
    }

    func beginSessionIfPossible(
        state: inout State,
        device: DeviceSummary
    ) -> Effect<Action> {
        let previousSession = state.session
        state.activeContactIDs.removeAll()
        state.isViewingStopped = false
        state.remediation = nil
        state.session = nil

        guard state.lifecycle == .active,
              device.pairingState == .paired,
              device.reachability == .reachable
        else {
            guard let previousSession else {
                return cancelSessionEffects()
            }
            return .concatenate(
                cancelSessionEffects(),
                closeSessionEffect(session: previousSession)
            )
        }

        let attemptID = uuid()
        state.session = ActiveRemoteSession(
            attemptID: attemptID,
            device: device,
            evaluatedAt: date.now
        )
        let connect = connectEffect(
            attemptID: attemptID,
            deviceID: device.id,
            cancelID: .connect
        )
        guard let previousSession else {
            return .concatenate(
                cancelSessionEffects(),
                connect
            )
        }
        return .concatenate(
            cancelSessionEffects(),
            closeSessionEffect(session: previousSession),
            connect
        )
    }

    func reconcileRoster(
        state: inout State,
        devices: [DeviceSummary]
    ) -> Effect<Action> {
        let previousSelection = state.selectedDeviceID
        state.roster = DeviceRoster(devices: devices)
        state.selectedDeviceID = state.roster.selectionID(
            preserving: previousSelection
        )
        if state.selectedDeviceID != previousSelection {
            state.isViewingStopped = false
        }

        let deviceUpdate = updateActiveDevice(state: &state)

        guard !state.isViewingStopped,
              state.selectedDeviceID != previousSelection
              || state.session == nil,
              let selectedDevice = state.selectedDevice
        else {
            if state.selectedDeviceID == nil {
                let previousSession = state.session
                state.session = nil
                guard let previousSession else {
                    return cancelSessionEffects()
                }
                return .concatenate(
                    cancelSessionEffects(),
                    closeSessionEffect(session: previousSession)
                )
            }
            return deviceUpdate
        }

        return .concatenate(
            deviceUpdate,
            beginSessionIfPossible(
                state: &state,
                device: selectedDevice
            )
        )
    }

    private func updateActiveDevice(
        state: inout State
    ) -> Effect<Action> {
        guard var session = state.session,
              let device = state.selectedDevice,
              session.device.id == device.id
        else {
            return .none
        }

        let wasAcceptingInput = session.acceptsInput
        session.device = device
        if var remoteState = session.remoteState {
            _ = remoteState.apply(
                SessionUpdate(
                    generation: remoteState.generation,
                    event: .deviceInfoUpdated(device)
                )
            )
            session.remoteState = remoteState
        }
        state.session = session
        if device.pairingState != .paired {
            session.connectionError = .needsPairing
            state.session = session
            state.remediation = DeviceHubRemediation(error: .needsPairing)
            state.activeContactIDs.removeAll()
            return .concatenate(
                cancelSessionEffects(),
                closeSessionEffect(session: session)
            )
        }
        guard wasAcceptingInput, !session.acceptsInput else {
            return .none
        }
        DeviceHubFeatureTrace.emit(
            "input_revoked source=availability_update"
        )
        return .concatenate(
            revokeInput(state: &state),
            .cancel(id: CancelID.commands)
        )
    }
}

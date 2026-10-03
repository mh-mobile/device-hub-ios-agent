import DeviceHubCore
@testable import DeviceHubUI
import SwiftUI
import Testing

@Suite("Screen idle-timer policy")
struct ScreenIdlePolicyTests {
    @Test("a remote screen on display keeps the controller awake while active")
    func remoteScreenKeepsAwake() {
        for presentation in [RemoteSessionPresentation.live, .viewingOnly] {
            #expect(ScreenIdlePolicy.isDisabled(
                isPairingPresented: false,
                hasPairingRemediation: false,
                presentation: presentation,
                scenePhase: .active
            ))
            #expect(!ScreenIdlePolicy.isDisabled(
                isPairingPresented: false,
                hasPairingRemediation: false,
                presentation: presentation,
                scenePhase: .inactive
            ))
        }
        for presentation in [
            RemoteSessionPresentation.offline,
            .ended(.connectionLost),
            .connecting(.locating),
            nil
        ] {
            #expect(!ScreenIdlePolicy.isDisabled(
                isPairingPresented: false,
                hasPairingRemediation: false,
                presentation: presentation,
                scenePhase: .active
            ))
        }
    }

    @Test("pairing keeps the controller awake until it needs recovery")
    func pairingKeepsAwake() {
        #expect(ScreenIdlePolicy.isDisabled(
            isPairingPresented: true,
            hasPairingRemediation: false,
            presentation: nil,
            scenePhase: .active
        ))
        #expect(!ScreenIdlePolicy.isDisabled(
            isPairingPresented: true,
            hasPairingRemediation: true,
            presentation: nil,
            scenePhase: .active
        ))
        for phase in [ScenePhase.inactive, .background] {
            #expect(!ScreenIdlePolicy.isDisabled(
                isPairingPresented: true,
                hasPairingRemediation: false,
                presentation: .live,
                scenePhase: phase
            ))
        }
    }
}

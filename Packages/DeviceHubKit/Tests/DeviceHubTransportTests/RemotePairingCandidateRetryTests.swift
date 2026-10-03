import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Foundation
import Testing

@Suite("Remote-pairing candidate retry")
struct RemotePairingCandidateRetryTests {
    @Test(
        "a Pair Verify that could not reach the device is retried without a new announcement",
        .timeLimit(.minutes(1))
    )
    func unreachableCandidateIsRetried() async throws {
        let browser = BrowserProbe()
        let outcomes = OutcomeSequence([.unreachable, .verified])
        let transport = makeTransport(
            browser: browser,
            verifyCandidate: { _, _ in await outcomes.next() }
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        try await browser.emit(.resolved(resolvedService()))
        let availability = try await iterator.next()

        expectNoDifference(
            availability,
            [
                RemotePairingAvailability(
                    deviceID: DeviceID(rawValue: "test-phone"),
                    reachability: .reachable
                )
            ]
        )
        #expect(await outcomes.callCount == 2)
    }

    @Test(
        "unknown announcements cannot crowd out a known device",
        .timeLimit(.minutes(1))
    )
    func unknownAnnouncementsDoNotCrowdOutKnownDevice() async throws {
        let browser = BrowserProbe()
        let observations = ObservationProbe()
        let transport = makeTransport(browser: browser, observations: observations)
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        for index in 0 ..< 65 {
            let stranger = try #require(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))?
                .uuidString)
            let endpoint = try NativeResolvedEndpoint(
                family: .ipv4,
                address: Data([192, 168, 1, UInt8(100 + index)]),
                scopeID: 0,
                port: 49155
            )
            try await browser.emit(.resolved(BonjourResolvedServiceSnapshot(
                serviceName: stranger,
                hostName: "stranger-\(index).local.",
                port: 49155,
                resolvedEndpoints: [endpoint],
                txtRecord: makeTXT([
                    ("identifier", stranger),
                    ("authTag", "AQIDBAUG"),
                    ("flags", "0"),
                    ("ver", "26"),
                    ("minVer", "8")
                ])
            )))
        }
        await observations.wait(forCount: 65)
        // Strangers are still capped: the 65th is not kept.
        let kept = await transport.browsingState?.servicesByName.count
        #expect(kept == 64)

        try await browser.emit(.resolved(resolvedService()))

        let availability = try await iterator.next()
        expectNoDifference(
            availability,
            [RemotePairingAvailability(deviceID: DeviceID(rawValue: "test-phone"), reachability: .reachable)]
        )
    }

    @Test("a device that rejects Pair Verify is not retried")
    func rejectedCandidateIsNotRetried() async throws {
        let browser = BrowserProbe()
        let observations = ObservationProbe()
        let outcomes = OutcomeSequence([.rejected, .verified])
        let transport = makeTransport(
            browser: browser,
            observations: observations,
            verifyCandidate: { _, _ in await outcomes.next() }
        )
        let stream = await transport.availability()
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        try await browser.emit(.resolved(resolvedService()))
        await observations.wait(forCount: 1)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await outcomes.callCount == 1)
    }
}

private actor OutcomeSequence {
    private var outcomes: [CandidateVerificationOutcome]
    private(set) var callCount = 0

    init(_ outcomes: [CandidateVerificationOutcome]) {
        self.outcomes = outcomes
    }

    func next() -> CandidateVerificationOutcome {
        callCount += 1
        return outcomes.isEmpty ? .rejected : outcomes.removeFirst()
    }
}

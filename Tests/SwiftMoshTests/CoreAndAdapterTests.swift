import Foundation
import XCTest
@testable import MoshCompression
@testable import MoshCore
@testable import MoshCryptoOCB
@testable import MoshProtoLite
@testable import MoshTransport
@testable import MoshWire

final class CoreAndAdapterTests: XCTestCase {
    func testConfigAndBasicCodableTypes() throws {
        let endpoint = makeEndpoint()
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 60001)

        let config = MoshClientConfig(maxReceiveStates: 0, mtu: 64)
        XCTAssertEqual(config.maxReceiveStates, 1)
        XCTAssertEqual(config.mtu, 128)

        let snapshot = MoshSnapshot(endpoint: endpoint, transportState: Data([1, 2]), createdAtMs: 3, schemaVersion: 4)
        let roundTrip = try JSONDecoder().decode(MoshSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTrip, snapshot)

        let hostOp = MoshHostOp.resize(cols: 80, rows: 24)
        let hostOpRoundTrip = try JSONDecoder().decode(MoshHostOp.self, from: JSONEncoder().encode(hostOp))
        XCTAssertEqual(hostOpRoundTrip, hostOp)

        let clientOp = MoshClientOp.keystrokes(Data([0x41]))
        let clientOpRoundTrip = try JSONDecoder().decode(MoshClientOp.self, from: JSONEncoder().encode(clientOp))
        XCTAssertEqual(clientOpRoundTrip, clientOp)
    }

    func testSessionInvalidEndpointAndNotStartedErrors() async throws {
        let invalid = MoshClientSession(endpoint: MoshEndpoint(host: "", port: 0, keyBase64_22: makeEndpoint().keyBase64_22))
        do {
            try await invalid.start()
            XCTFail("Expected invalidEndpoint")
        } catch {
            guard case .invalidEndpoint = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let (session, _) = await makeInMemorySession(config: .init())
        do {
            try await session.enqueue(.keystrokes(Data([0x41])))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await session.stop()
        let drainedAfterStop = await session.drainHostOps()
        XCTAssertEqual(drainedAfterStop, [])
    }

    func testSessionRoundTripAndReceiveFiltersAndFallback() async throws {
        setenv("SWIFTMOSH_DEBUG_REAL_E2E", "1", 1)
        defer { unsetenv("SWIFTMOSH_DEBUG_REAL_E2E") }

        var config = MoshClientConfig(maxReceiveStates: 2, mtu: 256, useNetworkCrypto: false)
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        // start called twice is a no-op branch
        try await session.start()

        try await session.enqueue(.keystrokes(Data("abc".utf8)))

        let outbound = try await server.receivePayload()
        let outboundInstruction = try decodeInstructionPayload(
            outbound.payload,
            compressed: true
        )
        let outboundUser = try UserMessage(decoding: outboundInstruction.diff ?? Data())
        XCTAssertEqual(outboundUser.instructions.count, 1)
        if case .keystroke(let bytes) = outboundUser.instructions[0] {
            XCTAssertEqual(bytes, Data("abc".utf8))
        } else {
            XCTFail("Expected keystroke")
        }

        try await session.enqueue(.resize(cols: 90, rows: 31))
        let resizeOutbound = try await server.receivePayload()
        let resizeInstruction = try decodeInstructionPayload(
            resizeOutbound.payload,
            compressed: true
        )
        let resizeUser = try UserMessage(decoding: resizeInstruction.diff ?? Data())
        XCTAssertEqual(resizeUser.instructions.count, 1)
        if case .resize(let width, let height) = resizeUser.instructions[0] {
            XCTAssertEqual(width, 90)
            XCTAssertEqual(height, 31)
        } else {
            XCTFail("Expected resize")
        }

        let seqEmpty = await server.reserveOutgoingSequence()
        try await server.sendPayload(Data(), sequence: seqEmpty)
        let emptyDrain = await drainEventually(session: session)
        XCTAssertEqual(emptyDrain, [])

        let seq2 = await server.reserveOutgoingSequence()
        let noDiff = TransportInstruction(protocolVersion: MoshWire.protocolVersion)
        try await server.sendPayload(
            try encodeInstructionPayload(noDiff, compressed: true),
            sequence: seq2
        )
        _ = await drainEventually(session: session)

        let seq3 = await server.reserveOutgoingSequence()
        let invalidHostMessage = TransportInstruction(protocolVersion: MoshWire.protocolVersion, diff: Data([0xFF, 0x00, 0xAA]))
        try await server.sendPayload(
            try encodeInstructionPayload(invalidHostMessage, compressed: true),
            sequence: seq3
        )
        let fallback = await drainEventually(session: session)
        XCTAssertEqual(fallback, [.hostBytes(Data([0xFF, 0x00, 0xAA]))])

        let seqRaw = await server.reserveOutgoingSequence()
        let rawInstruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            diff: HostMessage(instructions: [.hostBytes(Data("B".utf8))]).encoded()
        )
        try await server.sendPayload(
            try encodeInstructionPayload(rawInstruction, compressed: false),
            sequence: seqRaw
        )
        let rawFallback = await drainEventually(session: session)
        XCTAssertEqual(rawFallback, [.hostBytes(Data("B".utf8))])

        let seq4 = await server.reserveOutgoingSequence()
        let hostMessage = HostMessage(instructions: [
            .hostBytes(Data("A".utf8)),
            .resize(width: 120, height: 40),
            .echoAck(55)
        ])
        let valid = TransportInstruction(protocolVersion: MoshWire.protocolVersion, diff: hostMessage.encoded())
        try await server.sendPayload(
            try encodeInstructionPayload(valid, compressed: true),
            sequence: seq4
        )

        let drained = await drainEventually(session: session)
        // maxReceiveStates=2 trimming branch
        XCTAssertEqual(drained.count, 2)
        guard drained.count == 2 else {
            XCTFail("Expected two drained host ops")
            await session.stop()
            await server.stop()
            return
        }
        XCTAssertEqual(drained[0], .resize(cols: 120, rows: 40))
        XCTAssertEqual(drained[1], .echoAck(55))

        let seqMismatch = await server.reserveOutgoingSequence()
        let versionMismatch = TransportInstruction(
            protocolVersion: 999,
            diff: HostMessage(instructions: [.hostBytes(Data("x".utf8))]).encoded()
        )
        try await server.sendPayload(
            try encodeInstructionPayload(versionMismatch, compressed: true),
            sequence: seqMismatch
        )

        guard let failure = await waitForFailure(session: session, timeoutNs: 800_000_000) else {
            XCTFail("Expected protocol mismatch to fail session")
            await session.stop()
            await server.stop()
            return
        }
        guard case .protocolViolation(let message) = failure else {
            XCTFail("Unexpected failure: \(failure)")
            await session.stop()
            await server.stop()
            return
        }
        XCTAssertTrue(message.contains("protocol mismatch"))

        await session.stop()
        await server.stop()
    }

    func testSnapshotAndRestoreBranches() async throws {
        let endpoint = makeEndpoint()
        let baseConfig = MoshClientConfig(sendMinDelayMs: 5, maxReceiveStates: 9, ackIntervalMs: 7, ackDelayMs: 6, mtu: 300)
        let session = MoshClientSession(endpoint: endpoint, config: baseConfig)

        let snap1 = try await session.makeSnapshot()
        XCTAssertEqual(snap1.schemaVersion, 1)

        do {
            _ = try await MoshClientSession.restore(from: MoshSnapshot(endpoint: endpoint, transportState: Data(), createdAtMs: 0, schemaVersion: 2))
            XCTFail("Expected badSnapshotSchema")
        } catch {
            guard case .badSnapshotSchema(2) = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await MoshClientSession.restore(from: MoshSnapshot(endpoint: endpoint, transportState: Data([0xFF]), createdAtMs: 0, schemaVersion: 1))
            XCTFail("Expected decodeFailure")
        } catch {
            guard case .decodeFailure = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let restoredDefault = try await MoshClientSession.restore(from: snap1)
        let restoredDefaultConfig = await restoredDefault.config
        XCTAssertEqual(restoredDefaultConfig, baseConfig)

        let override = MoshClientConfig(sendMinDelayMs: 1, maxReceiveStates: 2, ackIntervalMs: 3, ackDelayMs: 4, mtu: 512)
        let restoredOverride = try await MoshClientSession.restore(from: snap1, config: override)
        let restoredOverrideConfig = await restoredOverride.config
        XCTAssertEqual(restoredOverrideConfig, override)

        // Cover pendingTransportSnapshot restoration in start().
        try await restoredDefault.start()
        await restoredDefault.stop()
        await restoredOverride.stop()
    }

    func testSnapshotEncodeFailureInjectedEncoder() async {
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(),
            endpointFactory: { _, _ in InMemoryDatagramEndpoint() },
            snapshotEncoder: { _ in throw EncodeSentinel.failure }
        )

        do {
            _ = try await session.makeSnapshot()
            XCTFail("Expected encodeFailure")
        } catch {
            guard case .encodeFailure = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSessionReceiveLoopIterationGuardAndNonCancelledCatch() async throws {
        setenv("SWIFTMOSH_DEBUG_REAL_E2E", "1", 1)
        defer { unsetenv("SWIFTMOSH_DEBUG_REAL_E2E") }

        let guardSession = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(),
            endpointFactory: { _, _ in InMemoryDatagramEndpoint() },
            snapshotEncoder: defaultSnapshotEncoder
        )
        let shouldContinue = await guardSession._testRunReceiveLoopIteration()
        XCTAssertFalse(shouldContinue)

        let failingEndpoint = AlwaysFailingReceiveEndpoint()
        let failingSession = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(),
            endpointFactory: { _, _ in failingEndpoint },
            snapshotEncoder: defaultSnapshotEncoder
        )

        try await failingSession.start()
        try? await Task.sleep(nanoseconds: 20_000_000)
        let attempts = await failingEndpoint.receiveAttempts()
        XCTAssertGreaterThan(attempts, 0)
        await failingSession.stop()
    }

    func testSessionStartBranchCoverageAndFailureReset() async throws {
        let blocking = BlockingStartEndpoint()
        let blockingSession = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(useNetworkCrypto: false),
            endpointFactory: { _, _ in blocking },
            snapshotEncoder: defaultSnapshotEncoder
        )

        let firstStart = Task {
            try await blockingSession.start()
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let blockingState = await blockingSession.state
        XCTAssertEqual(blockingState, .starting)

        // start while .starting is a no-op branch
        try await blockingSession.start()
        await blocking.resumeStart()
        try await firstStart.value
        await blockingSession.stop()

        let startFailing = StartThrowsEndpoint()
        let startFailingSession = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(useNetworkCrypto: false),
            endpointFactory: { _, _ in startFailing },
            snapshotEncoder: defaultSnapshotEncoder
        )
        do {
            try await startFailingSession.start()
            XCTFail("Expected start failure")
        } catch {
            // start failure should reset back to idle in catch branch
            let startFailingState = await startFailingSession.state
            XCTAssertEqual(startFailingState, .idle)
        }
    }

    func testSessionFailureHooksAndClassificationCoverage() async throws {
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(useNetworkCrypto: false),
            endpointFactory: { _, _ in InMemoryDatagramEndpoint() },
            snapshotEncoder: defaultSnapshotEncoder
        )

        // Cover sendPayload not-started guard.
        do {
            try await session._testSendPayload(Data([0x01]))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // Cover failSession already-failed guard branch.
        await session._testFailSession(.transportFailure("first"))
        await session._testFailSession(.transportFailure("second"))

        // start() when already failed should throw sessionFailed.
        do {
            try await session.start()
            XCTFail("Expected sessionFailed")
        } catch {
            guard case .sessionFailed(.transportFailure("first")) = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // Cover classification branches.
        let cancelledClassification = await session._testClassifyReceiveError(TransportError.cancelled)
        XCTAssertEqual(cancelledClassification, .transportFailure("cancelled"))
        let malformedClassification = await session._testClassifyReceiveError(TransportError.malformedDatagram)
        guard case .transportFailure = malformedClassification else {
            return XCTFail("Expected transportFailure for malformedDatagram")
        }
        let cryptoClassification = await session._testClassifyReceiveError(OCBCipherError.authenticationFailed)
        XCTAssertEqual(cryptoClassification, .authenticationFailure("authenticationFailed"))
        let protoClassification = await session._testClassifyReceiveError(ProtoLiteError.truncated)
        guard case .protocolViolation = protoClassification else {
            return XCTFail("Expected protocolViolation for ProtoLiteError")
        }
        let wireClassification = await session._testClassifyReceiveError(MoshWireError.truncated)
        guard case .protocolViolation = wireClassification else {
            return XCTFail("Expected protocolViolation for MoshWireError")
        }
        let genericClassification = await session._testClassifyReceiveError(GenericSyntheticError.synthetic)
        XCTAssertNil(genericClassification)

        // Cover successful _testSendPayload path.
        var config = MoshClientConfig(useNetworkCrypto: false)
        config.localPort = nil
        let (startedSession, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await startedSession.start()
        try await startedSession._testSendPayload(Data())
        await startedSession.stop()
        await server.stop()
    }

    func testSessionCoverageDecodeAndMaintenanceBranches() async throws {
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(useNetworkCrypto: false),
            endpointFactory: { _, _ in InMemoryDatagramEndpoint() },
            snapshotEncoder: defaultSnapshotEncoder
        )

        // Cover duplicate/new-state guards + throwaway pruning + large applied state pruning.
        _ = try await session._testDecodeHostOps(
            instruction: TransportInstruction(protocolVersion: MoshWire.protocolVersion, oldNum: 0, newNum: 1)
        )
        let duplicate = try await session._testDecodeHostOps(
            instruction: TransportInstruction(protocolVersion: MoshWire.protocolVersion, oldNum: 0, newNum: 1)
        )
        XCTAssertEqual(duplicate, [])

        let oldAhead = try await session._testDecodeHostOps(
            instruction: TransportInstruction(protocolVersion: MoshWire.protocolVersion, oldNum: 9, newNum: 10)
        )
        XCTAssertEqual(oldAhead, [])

        for index in 2...4100 {
            _ = try await session._testDecodeHostOps(
                instruction: TransportInstruction(
                    protocolVersion: MoshWire.protocolVersion,
                    oldNum: UInt64(index - 1),
                    newNum: UInt64(index)
                )
            )
        }
        _ = try await session._testDecodeHostOps(
            instruction: TransportInstruction(protocolVersion: MoshWire.protocolVersion, throwawayNum: 4096)
        )

        // Cover updateRtt guard branch with out-of-range sample and helper accessor.
        var now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        while now16 < 6_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        }
        _ = try await session._testDecodeHostOps(
            instruction: TransportInstruction(protocolVersion: MoshWire.protocolVersion),
            timestampReply: 0
        )
        let currentRto = await session._testCurrentRtoMs()
        XCTAssertGreaterThan(currentRto, 0)
        await session._testApplyRttSample(0)

        // Cover raw (uncompressed) decode path in test hook.
        _ = try await session._testDecodeHostOps(
            instruction: TransportInstruction(
                protocolVersion: MoshWire.protocolVersion,
                diff: HostMessage(instructions: [.hostBytes(Data("raw".utf8))]).encoded()
            ),
            compressed: false
        )

        // Cover maintenanceLoop guard (!running) branch.
        await session._testSetStateForMaintenanceCoverage(
            state: .idle,
            lastInboundAtMs: TransportClock.nowMs(),
            lastOutboundAtMs: TransportClock.nowMs(),
            lastAckSentAtMs: TransportClock.nowMs(),
            latestReceivedStateNum: 0,
            lastAckReportedNum: 0,
            ackDirtyAtMs: nil
        )
        await session._testRunMaintenanceLoopForCoverage()

        // Cover maintenanceLoop generic catch branch by forcing heartbeat send with nil engine.
        await session._testSetStateForMaintenanceCoverage(
            state: .running,
            lastInboundAtMs: TransportClock.nowMs(),
            lastOutboundAtMs: 0,
            lastAckSentAtMs: TransportClock.nowMs(),
            latestReceivedStateNum: 0,
            lastAckReportedNum: 0,
            ackDirtyAtMs: nil
        )
        await session._testRunMaintenanceLoopForCoverage()
        guard case .failed(.transportFailure) = await session.state else {
            return XCTFail("Expected maintenance generic catch to fail the session")
        }

        // Cover maybeSendAck interval branch that emits an ack-only frame.
        let ackSession = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(useNetworkCrypto: false),
            endpointFactory: { _, _ in InMemoryDatagramEndpoint() },
            snapshotEncoder: defaultSnapshotEncoder
        )
        await ackSession._testSetStateForMaintenanceCoverage(
            state: .running,
            lastInboundAtMs: TransportClock.nowMs(),
            lastOutboundAtMs: TransportClock.nowMs(),
            lastAckSentAtMs: 0,
            latestReceivedStateNum: 2,
            lastAckReportedNum: 0,
            ackDirtyAtMs: nil
        )
        await ackSession._testRunMaintenanceLoopForCoverage()
    }

    func testSessionRttAndReliabilityBranchCoverageHelpers() async throws {
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: .init(useNetworkCrypto: false),
            endpointFactory: { _, _ in InMemoryDatagramEndpoint() },
            snapshotEncoder: defaultSnapshotEncoder
        )

        let emptyHasContent = await session._testInstructionHasContent(TransportInstruction())
        let oldNumHasContent = await session._testInstructionHasContent(TransportInstruction(oldNum: 1))
        let newNumHasContent = await session._testInstructionHasContent(TransportInstruction(newNum: 1))
        let ackNumHasContent = await session._testInstructionHasContent(TransportInstruction(ackNum: 1))
        let throwawayHasContent = await session._testInstructionHasContent(TransportInstruction(throwawayNum: 1))
        let diffHasContent = await session._testInstructionHasContent(TransportInstruction(diff: Data([0xAA])))
        let chaffHasContent = await session._testInstructionHasContent(TransportInstruction(chaff: Data([0xBB])))
        XCTAssertFalse(emptyHasContent)
        XCTAssertTrue(oldNumHasContent)
        XCTAssertTrue(newNumHasContent)
        XCTAssertTrue(ackNumHasContent)
        XCTAssertTrue(throwawayHasContent)
        XCTAssertTrue(diffHasContent)
        XCTAssertTrue(chaffHasContent)

        await session._testSetRttState(srttMs: nil, rttvarMs: nil)
        await session._testApplyRttSample(120)
        await session._testApplyRttSample(140)
        await session._testSetRttState(srttMs: 80, rttvarMs: nil)
        await session._testApplyRttSample(90)

        await session._testSetRttState(srttMs: nil, rttvarMs: nil)
        let now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        await session._testUpdateRtt(timestampReply: now16 &- 20)
        let currentRto = await session._testCurrentRtoMs()
        XCTAssertGreaterThan(currentRto, 0)

        await session._testAcknowledgePendingOutbound(through: 999)
        await session._testPruneAppliedRemoteStates(before: 0)

        let largeAppliedStateSet = Set((5_000...9_095).map(UInt64.init))
        await session._testSetAppliedRemoteStates(largeAppliedStateSet, latestReceivedStateNum: 100)
        _ = try await session._testDecodeHostOps(
            instruction: TransportInstruction(
                protocolVersion: MoshWire.protocolVersion,
                oldNum: 100,
                newNum: 101
            )
        )

        await session._testSeedPendingOutboundOrderWithoutPayload(stateNum: 77)
        try await session._testRunProcessRetransmitQueue(nowMs: UInt64.max)

        await session._testSetLastOutboundAtMs(UInt64.max)
        try await session._testRunMaybeSendHeartbeat(nowMs: 0)
    }

    func testAckWithoutDirtyStateAndFutureLastSendCoverage() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 1,
            maxReceiveStates: 8,
            ackIntervalMs: 1,
            ackDelayMs: 2_000,
            networkTimeoutMs: 2_000,
            maxRetransmitCount: 3,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        await session._testSetAckState(
            latestReceivedStateNum: 7,
            lastAckReportedNum: 0,
            lastAckSentAtMs: 0,
            ackDirtyAtMs: nil
        )
        try await session._testRunMaybeSendAck(nowMs: UInt64(config.ackIntervalMs) + 1)

        let ackPayload = try await receivePayloadEventually(engine: server, timeoutNs: 900_000_000)
        let ackInstruction = try decodeInstructionPayload(ackPayload.payload, compressed: true)
        XCTAssertNil(ackInstruction.diff)
        XCTAssertEqual(ackInstruction.ackNum, 7)

        await session._testSetLastStateSendAtMs(UInt64.max)
        try await session._testApplySendMinDelayIfNeeded()

        await session.stop()
        await server.stop()
    }

    func testRetransmitRetryThenAckClearsQueue() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 1_000,
            ackDelayMs: 100,
            networkTimeoutMs: 2_000,
            maxRetransmitCount: 3,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("r".utf8)))
        let queued = await waitForPendingOutboundCount(session: session, expected: 1, timeoutNs: 300_000_000)
        XCTAssertTrue(queued)

        let initialSend = try await receivePayloadEventually(engine: server, timeoutNs: 400_000_000)
        let initialInstruction = try decodeInstructionPayload(initialSend.payload, compressed: true)
        XCTAssertEqual(initialInstruction.newNum, 1)
        XCTAssertNotNil(initialInstruction.diff)

        let retrySend = try await receivePayloadEventually(engine: server, timeoutNs: 700_000_000)
        let retryInstruction = try decodeInstructionPayload(retrySend.payload, compressed: true)
        XCTAssertEqual(retryInstruction.newNum, 1)
        XCTAssertEqual(retryInstruction.diff, initialInstruction.diff)

        let ack = TransportInstruction(protocolVersion: MoshWire.protocolVersion, ackNum: 1)
        let ackSeq = await server.reserveOutgoingSequence()
        try await server.sendPayload(
            try encodeInstructionPayload(ack, compressed: true),
            sequence: ackSeq
        )

        let emptied = await waitForPendingOutboundCount(session: session, expected: 0, timeoutNs: 700_000_000)
        XCTAssertTrue(emptied)

        await session.stop()
        await server.stop()
    }

    func testRetryLimitFailure() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 1_000,
            ackDelayMs: 100,
            networkTimeoutMs: 2_000,
            maxRetransmitCount: 1,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("x".utf8)))
        _ = try await receivePayloadEventually(engine: server, timeoutNs: 400_000_000) // initial send
        _ = try await receivePayloadEventually(engine: server, timeoutNs: 700_000_000) // one retry

        guard let failure = await waitForFailure(session: session, timeoutNs: 1_200_000_000) else {
            XCTFail("Expected retry limit failure")
            await session.stop()
            await server.stop()
            return
        }
        guard case .retryLimitExceeded(let stateNum, let retryCount) = failure else {
            XCTFail("Unexpected failure: \(failure)")
            await session.stop()
            await server.stop()
            return
        }
        XCTAssertEqual(stateNum, 1)
        XCTAssertEqual(retryCount, 1)

        do {
            try await session.enqueue(.keystrokes(Data("y".utf8)))
            XCTFail("Expected sessionFailed after retry limit failure")
        } catch {
            guard case .sessionFailed(.retryLimitExceeded(let stateNum, let retryCount)) = error as? MoshSessionError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stateNum, 1)
            XCTAssertEqual(retryCount, 1)
        }

        await session.stop()
        await server.stop()
    }

    func testTimeoutFailure() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 1_000,
            ackDelayMs: 100,
            networkTimeoutMs: 500,
            maxRetransmitCount: 3,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        guard let failure = await waitForFailure(session: session, timeoutNs: 1_500_000_000) else {
            XCTFail("Expected timeout failure")
            await session.stop()
            await server.stop()
            return
        }
        guard case .timeout(let timeoutMs) = failure else {
            XCTFail("Unexpected failure: \(failure)")
            await session.stop()
            await server.stop()
            return
        }
        XCTAssertEqual(timeoutMs, 500)

        await session.stop()
        await server.stop()
    }

    func testCircuitBreakerTripping() async throws {
        let failingEndpoint = AlwaysFailingReceiveEndpoint()
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: MoshClientConfig(
                sendMinDelayMs: 0,
                maxReceiveStates: 8,
                ackIntervalMs: 1_000,
                ackDelayMs: 100,
                networkTimeoutMs: 8_000,
                maxRetransmitCount: 3,
                initialRtoMs: 100,
                maxRtoMs: 100,
                heartbeatIntervalMs: 10_000,
                mtu: 256,
                useNetworkCrypto: false
            ),
            endpointFactory: { _, _ in failingEndpoint },
            snapshotEncoder: defaultSnapshotEncoder
        )

        try await session.start()

        guard let failure = await waitForFailure(session: session, timeoutNs: 6_000_000_000) else {
            XCTFail("Expected circuit-breaker failure")
            await session.stop()
            return
        }
        guard case .circuitBreakerTripped(let failures, let message) = failure else {
            XCTFail("Unexpected failure: \(failure)")
            await session.stop()
            return
        }
        XCTAssertEqual(failures, 8)
        XCTAssertTrue(message.contains("synthetic"))

        await session.stop()
    }

    func testPacketLossSimulationConvergesViaRetransmit() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 1_000,
            ackDelayMs: 100,
            networkTimeoutMs: 3_000,
            maxRetransmitCount: 5,
            initialRtoMs: 80,
            maxRtoMs: 80,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (rawClient, rawServer) = await InMemoryDatagramPair.makeLinked()
        let chaoticClient = ChaosDatagramEndpoint(
            base: rawClient,
            dropSendOrdinals: [1, 2]
        )
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: config,
            endpointFactory: { _, _ in chaoticClient },
            snapshotEncoder: defaultSnapshotEncoder
        )
        let server = TransportEngine(endpoint: rawServer, outgoingDirection: .toClient, mtu: config.mtu)

        try await server.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("loss".utf8)))
        let converged = try await receivePayloadEventually(engine: server, timeoutNs: 2_500_000_000)
        let convergedInstruction = try decodeInstructionPayload(converged.payload, compressed: true)
        XCTAssertEqual(convergedInstruction.newNum, 1)
        let user = try UserMessage(decoding: convergedInstruction.diff ?? Data())
        XCTAssertEqual(user.instructions.count, 1)
        if case .keystroke(let bytes) = user.instructions[0] {
            XCTAssertEqual(bytes, Data("loss".utf8))
        } else {
            XCTFail("Expected keystroke after retransmit convergence")
        }
        let droppedCount = await chaoticClient.droppedSendCount()
        XCTAssertEqual(droppedCount, 2)

        let ack = TransportInstruction(protocolVersion: MoshWire.protocolVersion, ackNum: 1)
        let ackSeq = await server.reserveOutgoingSequence()
        try await server.sendPayload(
            try encodeInstructionPayload(ack, compressed: true),
            sequence: ackSeq
        )
        let queueCleared = await waitForPendingOutboundCount(session: session, expected: 0, timeoutNs: 1_000_000_000)
        XCTAssertTrue(queueCleared)

        await session.stop()
        await server.stop()
    }

    func testJitterSimulationPreservesOrderingAndSessionHealth() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 1_000,
            ackDelayMs: 100,
            networkTimeoutMs: 3_000,
            maxRetransmitCount: 4,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (rawClient, rawServer) = await InMemoryDatagramPair.makeLinked()
        let chaoticClient = ChaosDatagramEndpoint(
            base: rawClient,
            dropSendOrdinals: [],
            sendDelayMsByOrdinal: [1: 40, 2: 10, 3: 30]
        )
        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: config,
            endpointFactory: { _, _ in chaoticClient },
            snapshotEncoder: defaultSnapshotEncoder
        )
        let server = TransportEngine(endpoint: rawServer, outgoingDirection: .toClient, mtu: config.mtu)

        try await server.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("j1".utf8)))
        try await session.enqueue(.keystrokes(Data("j2".utf8)))

        let first = try await receivePayloadEventually(engine: server, timeoutNs: 1_500_000_000)
        let second = try await receivePayloadEventually(engine: server, timeoutNs: 1_500_000_000)
        let firstInstruction = try decodeInstructionPayload(first.payload, compressed: true)
        let secondInstruction = try decodeInstructionPayload(second.payload, compressed: true)
        XCTAssertEqual(firstInstruction.newNum, 1)
        XCTAssertEqual(secondInstruction.newNum, 2)

        let ack = TransportInstruction(protocolVersion: MoshWire.protocolVersion, ackNum: 2)
        let ackSeq = await server.reserveOutgoingSequence()
        try await server.sendPayload(
            try encodeInstructionPayload(ack, compressed: true),
            sequence: ackSeq
        )
        let queueCleared = await waitForPendingOutboundCount(session: session, expected: 0, timeoutNs: 1_000_000_000)
        XCTAssertTrue(queueCleared)
        let sessionState = await session.state
        XCTAssertEqual(sessionState, .running)

        await session.stop()
        await server.stop()
    }

    func testRoamSimulationRebindsToNewPeerWithoutSessionRestart() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 1_000,
            ackDelayMs: 100,
            networkTimeoutMs: 4_000,
            maxRetransmitCount: 5,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let client = InMemoryDatagramEndpoint()
        let serverA = InMemoryDatagramEndpoint()
        await client.link(serverA)
        await serverA.link(client)

        let session = MoshClientSession(
            endpoint: makeEndpoint(),
            config: config,
            endpointFactory: { _, _ in client },
            snapshotEncoder: defaultSnapshotEncoder
        )
        let serverEngineA = TransportEngine(endpoint: serverA, outgoingDirection: .toClient, mtu: config.mtu)
        try await serverEngineA.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("before-roam".utf8)))
        let beforeRoam = try await receivePayloadEventually(engine: serverEngineA, timeoutNs: 1_000_000_000)
        let beforeRoamInstruction = try decodeInstructionPayload(beforeRoam.payload, compressed: true)
        XCTAssertEqual(beforeRoamInstruction.newNum, 1)

        let ack1 = TransportInstruction(protocolVersion: MoshWire.protocolVersion, ackNum: 1)
        let ackSeq1 = await serverEngineA.reserveOutgoingSequence()
        try await serverEngineA.sendPayload(
            try encodeInstructionPayload(ack1, compressed: true),
            sequence: ackSeq1
        )
        let clearedBeforeRoam = await waitForPendingOutboundCount(session: session, expected: 0, timeoutNs: 1_000_000_000)
        XCTAssertTrue(clearedBeforeRoam)

        let transportSnapshot = await serverEngineA.makeSnapshot()
        await serverEngineA.stop()

        let serverB = InMemoryDatagramEndpoint()
        await client.link(serverB)
        await serverB.link(client)
        let serverEngineB = TransportEngine(endpoint: serverB, outgoingDirection: .toClient, mtu: config.mtu)
        await serverEngineB.restore(from: transportSnapshot)
        try await serverEngineB.start()

        try await session.enqueue(.keystrokes(Data("after-roam".utf8)))
        let afterRoam = try await receivePayloadEventually(engine: serverEngineB, timeoutNs: 1_500_000_000)
        let afterRoamInstruction = try decodeInstructionPayload(afterRoam.payload, compressed: true)
        XCTAssertEqual(afterRoamInstruction.newNum, 2)
        let afterUser = try UserMessage(decoding: afterRoamInstruction.diff ?? Data())
        XCTAssertEqual(afterUser.instructions.count, 1)
        if case .keystroke(let bytes) = afterUser.instructions[0] {
            XCTAssertEqual(bytes, Data("after-roam".utf8))
        } else {
            XCTFail("Expected keystroke after roam")
        }

        let ack2 = TransportInstruction(protocolVersion: MoshWire.protocolVersion, ackNum: 2)
        let ackSeq2 = await serverEngineB.reserveOutgoingSequence()
        try await serverEngineB.sendPayload(
            try encodeInstructionPayload(ack2, compressed: true),
            sequence: ackSeq2
        )
        let clearedAfterRoam = await waitForPendingOutboundCount(session: session, expected: 0, timeoutNs: 1_000_000_000)
        XCTAssertTrue(clearedAfterRoam)
        let sessionState = await session.state
        XCTAssertEqual(sessionState, .running)

        await session.stop()
        await serverEngineB.stop()
    }

    func testHostOpStreamYieldsAndFinishesOnStop() async throws {
        var config = MoshClientConfig(maxReceiveStates: 8, mtu: 256, useNetworkCrypto: false)
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        let stream = await session.hostOpStream()
        let receivedTwo = expectation(description: "received two host ops")
        let finished = expectation(description: "host op stream finished")
        let collector = HostOpCollector()

        let reader = Task {
            for await op in stream {
                let count = await collector.appendAndCount(op)
                if count == 2 {
                    receivedTwo.fulfill()
                }
            }
            finished.fulfill()
        }

        let seq = await server.reserveOutgoingSequence()
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: 0,
            newNum: 1,
            diff: HostMessage(instructions: [.hostBytes(Data("x".utf8)), .echoAck(9)]).encoded()
        )
        try await server.sendPayload(
            try encodeInstructionPayload(instruction, compressed: true),
            sequence: seq
        )

        await fulfillment(of: [receivedTwo], timeout: 1.0)
        let yielded = await collector.values()
        XCTAssertEqual(yielded, [.hostBytes(Data("x".utf8)), .echoAck(9)])

        await session.stop()
        await fulfillment(of: [finished], timeout: 1.0)
        _ = await reader.result
        await server.stop()
    }

    func testAckDelayAndHeartbeatWiring() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 10_000,
            ackDelayMs: 30,
            networkTimeoutMs: 2_000,
            maxRetransmitCount: 3,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 250,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        let inboundSeq = await server.reserveOutgoingSequence()
        let inboundInstruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: 0,
            newNum: 1,
            diff: HostMessage(instructions: [.hostBytes(Data("a".utf8))]).encoded()
        )
        try await server.sendPayload(
            try encodeInstructionPayload(inboundInstruction, compressed: true),
            sequence: inboundSeq
        )

        let ackPayload = try await receivePayloadEventually(engine: server, timeoutNs: 400_000_000)
        let ackInstruction = try decodeInstructionPayload(ackPayload.payload, compressed: true)
        XCTAssertNil(ackInstruction.diff)
        XCTAssertEqual(ackInstruction.ackNum, 1)

        let heartbeatStart = DispatchTime.now().uptimeNanoseconds
        let heartbeatPayload = try await receivePayloadEventually(engine: server, timeoutNs: 900_000_000)
        let heartbeatElapsedMs = (DispatchTime.now().uptimeNanoseconds - heartbeatStart) / 1_000_000
        let heartbeatInstruction = try decodeInstructionPayload(heartbeatPayload.payload, compressed: true)
        XCTAssertNil(heartbeatInstruction.diff)
        XCTAssertEqual(heartbeatInstruction.ackNum, 1)
        XCTAssertGreaterThanOrEqual(heartbeatElapsedMs, 180)

        await session.stop()
        await server.stop()
    }

    func testAckIntervalWiringFlushesDirtyAckBeforeDelay() async throws {
        var config = MoshClientConfig(
            sendMinDelayMs: 0,
            maxReceiveStates: 8,
            ackIntervalMs: 40,
            ackDelayMs: 2_000,
            networkTimeoutMs: 2_500,
            maxRetransmitCount: 3,
            initialRtoMs: 100,
            maxRtoMs: 100,
            heartbeatIntervalMs: 10_000,
            mtu: 256,
            useNetworkCrypto: false
        )
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        let inboundSeq = await server.reserveOutgoingSequence()
        let inboundInstruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: 0,
            newNum: 1,
            diff: HostMessage(instructions: [.hostBytes(Data("b".utf8))]).encoded()
        )
        try await server.sendPayload(
            try encodeInstructionPayload(inboundInstruction, compressed: true),
            sequence: inboundSeq
        )

        let ackPayload = try await receivePayloadEventually(engine: server, timeoutNs: 900_000_000)
        let ackInstruction = try decodeInstructionPayload(ackPayload.payload, compressed: true)
        XCTAssertNil(ackInstruction.diff)
        XCTAssertEqual(ackInstruction.ackNum, 1)

        await session.stop()
        await server.stop()
    }

    func testNetworkCryptoInMemoryRoundTripAndEncryptedEndpointErrorPaths() async throws {
        setenv("SWIFTMOSH_DEBUG_REAL_E2E", "1", 1)
        defer { unsetenv("SWIFTMOSH_DEBUG_REAL_E2E") }

        var config = MoshClientConfig(maxReceiveStates: 16, mtu: 256, useNetworkCrypto: true)
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("z".utf8)))
        let outbound = try await server.receivePayload()
        let outboundInstruction = try decodeInstructionPayload(outbound.payload, compressed: true)
        let outboundUser = try UserMessage(decoding: outboundInstruction.diff ?? Data())
        XCTAssertEqual(outboundUser.instructions.count, 1)

        let hostInstruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            diff: HostMessage(instructions: [.hostBytes(Data("q".utf8))]).encoded()
        )
        let seq = await server.reserveOutgoingSequence()
        try await server.sendPayload(
            try encodeInstructionPayload(hostInstruction, compressed: true),
            sequence: seq
        )
        let drained = await drainEventually(session: session)
        XCTAssertEqual(drained, [.hostBytes(Data("q".utf8))])

        await session.stop()
        await server.stop()

        let wrapped = BufferedDatagramEndpoint()
        let key = try MoshBase64Key(printableKey: makeEndpoint().keyBase64_22).raw
        let encrypted = try MoshEncryptedDatagramEndpoint(wrapping: wrapped, key: key)
        try await encrypted.start()

        let clearPacket = MoshPacket(
            sequence: 9,
            direction: .toServer,
            timestamp: 123,
            timestampReply: 456,
            payload: Data([0x10, 0x11])
        )
        let clearBytes = MoshPacketCodec.encode(clearPacket)
        try await encrypted.send(clearBytes)
        let wireDatagram = await wrapped.takeSentData()
        XCTAssertFalse(wireDatagram.isEmpty)

        await wrapped.inject(TransportDatagram(data: wireDatagram))
        let roundTripped = try await encrypted.receive()
        XCTAssertEqual(roundTripped.data, clearBytes)

        await wrapped.inject(TransportDatagram(data: Data([0x00, 0x01, 0x02])))
        do {
            _ = try await encrypted.receive()
            XCTFail("Expected truncated")
        } catch {
            guard case .truncated = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await wrapped.inject(TransportDatagram(data: Data(repeating: 0xAA, count: 8 + 15)))
        do {
            _ = try await encrypted.receive()
            XCTFail("Expected truncated encrypted-body")
        } catch {
            guard case .truncated = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let shortDirectional = MoshWire.directionalSequence(sequence: 123, direction: .toClient)
        let shortNonce = OCBNonce.from(messageID: 0, sequence: shortDirectional)
        let shortSeal = try OCBCipher(key: key).seal(plaintext: Data([0x01, 0x02, 0x03]), nonce: shortNonce)
        let shortPlainDatagram = encodeUInt64BE(shortDirectional) + shortSeal.ciphertext + shortSeal.tag
        await wrapped.inject(TransportDatagram(data: shortPlainDatagram))
        do {
            _ = try await encrypted.receive()
            XCTFail("Expected truncated plaintext")
        } catch {
            guard case .truncated = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var tampered = wireDatagram
        tampered[tampered.count - 1] ^= 0xFF
        await wrapped.inject(TransportDatagram(data: tampered))
        do {
            _ = try await encrypted.receive()
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error is OCBCipherError)
        }

        await encrypted.stop()
    }

    func testNetworkCryptoRoundTripWithDebugDisabled() async throws {
        unsetenv("SWIFTMOSH_DEBUG_REAL_E2E")

        var config = MoshClientConfig(maxReceiveStates: 8, mtu: 256, useNetworkCrypto: true)
        config.localPort = nil

        let (session, server) = await makeInMemorySession(config: config)
        try await server.start()
        try await session.start()

        try await session.enqueue(.keystrokes(Data("d".utf8)))
        let outbound = try await server.receivePayload()
        let outboundInstruction = try decodeInstructionPayload(outbound.payload, compressed: true)
        XCTAssertNotNil(outboundInstruction.diff)

        let hostInstruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            diff: HostMessage(instructions: [.hostBytes(Data("ok".utf8))]).encoded()
        )
        let seq = await server.reserveOutgoingSequence()
        try await server.sendPayload(
            try encodeInstructionPayload(hostInstruction, compressed: true),
            sequence: seq
        )
        let drained = await drainEventually(session: session)
        XCTAssertEqual(drained, [.hostBytes(Data("ok".utf8))])

        await session.stop()
        await server.stop()
    }

    private func makeEndpoint() -> MoshEndpoint {
        let raw = Data((0..<16).map(UInt8.init))
        let key = try! MoshBase64Key(raw: raw)
        return MoshEndpoint(host: "127.0.0.1", port: 60001, keyBase64_22: key.printable)
    }

    private func makeInMemorySession(config: MoshClientConfig) async -> (MoshClientSession, TransportEngine) {
        let (client, server) = await InMemoryDatagramPair.makeLinked()
        let endpoint = makeEndpoint()
        let configuredSession = MoshClientSession(
            endpoint: endpoint,
            config: config,
            endpointFactory: { _, _ in client },
            snapshotEncoder: defaultSnapshotEncoder
        )
        let serverEndpoint: any DatagramEndpoint
        if config.useNetworkCrypto {
            let key = try! MoshBase64Key(printableKey: endpoint.keyBase64_22)
            serverEndpoint = try! MoshEncryptedDatagramEndpoint(wrapping: server, key: key.raw)
        } else {
            serverEndpoint = server
        }
        let serverEngine = TransportEngine(endpoint: serverEndpoint, outgoingDirection: .toClient, mtu: config.mtu)
        return (configuredSession, serverEngine)
    }

    private func encodeInstructionPayload(
        _ instruction: TransportInstruction,
        compressed: Bool
    ) throws -> Data {
        if compressed {
            return try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib)
        } else {
            return instruction.encoded()
        }
    }

    private func decodeInstructionPayload(
        _ payload: Data,
        compressed: Bool
    ) throws -> TransportInstruction {
        let data: Data
        if compressed {
            data = try MoshCompressionCodec().decompress(payload, algorithm: .zlib)
        } else {
            data = payload
        }
        return try TransportInstruction(decoding: data)
    }

    private func drainEventually(session: MoshClientSession) async -> [MoshHostOp] {
        for _ in 0..<50 {
            let drained = await session.drainHostOps()
            if !drained.isEmpty {
                return drained
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return []
    }

    private func waitForFailure(
        session: MoshClientSession,
        timeoutNs: UInt64,
        stepNs: UInt64 = 20_000_000
    ) async -> MoshSessionFailure? {
        var waited: UInt64 = 0
        while waited < timeoutNs {
            let state = await session.state
            if case .failed(let failure) = state {
                return failure
            }
            try? await Task.sleep(nanoseconds: stepNs)
            waited &+= stepNs
        }

        let state = await session.state
        if case .failed(let failure) = state {
            return failure
        }
        return nil
    }

    private func waitForPendingOutboundCount(
        session: MoshClientSession,
        expected: Int,
        timeoutNs: UInt64,
        stepNs: UInt64 = 20_000_000
    ) async -> Bool {
        var waited: UInt64 = 0
        while waited < timeoutNs {
            if await session._testPendingOutboundCount() == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: stepNs)
            waited &+= stepNs
        }
        return await session._testPendingOutboundCount() == expected
    }

    private func receivePayloadEventually(
        engine: TransportEngine,
        timeoutNs: UInt64
    ) async throws -> TransportReceivedPayload {
        try await withThrowingTaskGroup(of: TransportReceivedPayload.self) { group in
            group.addTask {
                try await engine.receivePayload()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw TestTimeoutError.timedOut
            }

            guard let first = try await group.next() else {
                throw TestTimeoutError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    private enum TestTimeoutError: Error {
        case timedOut
    }
}

private func defaultSnapshotEncoder(_ blob: SessionStateBlob) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(blob)
}

private enum EncodeSentinel: Error {
    case failure
}

private enum GenericSyntheticError: Error {
    case synthetic
}

private actor HostOpCollector {
    private var entries: [MoshHostOp] = []

    func appendAndCount(_ op: MoshHostOp) -> Int {
        entries.append(op)
        return entries.count
    }

    func values() -> [MoshHostOp] {
        entries
    }
}

private actor AlwaysFailingReceiveEndpoint: DatagramEndpoint {
    private var started = false
    private var receiveCount = 0

    func start() async throws {
        started = true
    }

    func stop() async {
        started = false
    }

    func send(_ data: Data) async throws {
        guard started else {
            throw TransportError.notStarted
        }
    }

    func receive() async throws -> TransportDatagram {
        guard started else {
            throw TransportError.notStarted
        }
        receiveCount += 1
        try await Task.sleep(nanoseconds: 1_000_000)
        throw TransportError.networkFailure("synthetic")
    }

    func receiveAttempts() -> Int {
        receiveCount
    }
}

private actor StartThrowsEndpoint: DatagramEndpoint {
    func start() async throws {
        throw TransportError.networkFailure("start-failure")
    }

    func stop() async {}

    func send(_ data: Data) async throws {}

    func receive() async throws -> TransportDatagram {
        throw TransportError.cancelled
    }
}

private actor BlockingStartEndpoint: DatagramEndpoint {
    private var continuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func resumeStart() {
        continuation?.resume()
        continuation = nil
    }

    func stop() async {}

    func send(_ data: Data) async throws {}

    func receive() async throws -> TransportDatagram {
        throw TransportError.cancelled
    }
}

private actor BufferedDatagramEndpoint: DatagramEndpoint {
    private var started = false
    private var sent: [Data] = []
    private var inbox: [TransportDatagram] = []

    func start() async throws {
        started = true
    }

    func stop() async {
        started = false
        sent.removeAll(keepingCapacity: false)
        inbox.removeAll(keepingCapacity: false)
    }

    func send(_ data: Data) async throws {
        guard started else {
            throw TransportError.notStarted
        }
        sent.append(data)
    }

    func receive() async throws -> TransportDatagram {
        guard started else {
            throw TransportError.notStarted
        }
        guard !inbox.isEmpty else {
            throw TransportError.cancelled
        }
        return inbox.removeFirst()
    }

    func inject(_ datagram: TransportDatagram) {
        inbox.append(datagram)
    }

    func takeSentData() -> Data {
        guard !sent.isEmpty else { return Data() }
        return sent.removeFirst()
    }
}

private actor ChaosDatagramEndpoint: DatagramEndpoint {
    private let base: any DatagramEndpoint
    private let dropSendOrdinals: Set<Int>
    private let sendDelayMsByOrdinal: [Int: UInt64]
    private let receiveDelayMsByOrdinal: [Int: UInt64]

    private var sendOrdinal = 0
    private var receiveOrdinal = 0
    private var droppedSends = 0

    init(
        base: any DatagramEndpoint,
        dropSendOrdinals: Set<Int> = [],
        sendDelayMsByOrdinal: [Int: UInt64] = [:],
        receiveDelayMsByOrdinal: [Int: UInt64] = [:]
    ) {
        self.base = base
        self.dropSendOrdinals = dropSendOrdinals
        self.sendDelayMsByOrdinal = sendDelayMsByOrdinal
        self.receiveDelayMsByOrdinal = receiveDelayMsByOrdinal
    }

    func start() async throws {
        try await base.start()
    }

    func stop() async {
        await base.stop()
    }

    func send(_ data: Data) async throws {
        sendOrdinal += 1
        let current = sendOrdinal
        if let delayMs = sendDelayMsByOrdinal[current], delayMs > 0 {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        if dropSendOrdinals.contains(current) {
            droppedSends += 1
            return
        }
        try await base.send(data)
    }

    func receive() async throws -> TransportDatagram {
        let datagram = try await base.receive()
        receiveOrdinal += 1
        let current = receiveOrdinal
        if let delayMs = receiveDelayMsByOrdinal[current], delayMs > 0 {
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        return datagram
    }

    func droppedSendCount() -> Int {
        droppedSends
    }
}

private func encodeUInt64BE(_ value: UInt64) -> Data {
    var output = Data()
    for shift in stride(from: 56, through: 0, by: -8) {
        output.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
    return output
}

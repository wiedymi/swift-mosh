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

        let seq0 = await server.reserveOutgoingSequence()
        // payload < 16 branch -> no ops
        try await server.sendPayload(Data([0x01, 0x02, 0x03]), sequence: seq0)
        _ = await drainEventually(session: session)

        let seqEmpty = await server.reserveOutgoingSequence()
        try await server.sendPayload(Data(), sequence: seqEmpty)
        let emptyDrain = await drainEventually(session: session)
        XCTAssertEqual(emptyDrain, [])

        let seq1 = await server.reserveOutgoingSequence()
        let versionMismatch = TransportInstruction(protocolVersion: 999, diff: HostMessage(instructions: [.hostBytes(Data("x".utf8))]).encoded())
        try await server.sendPayload(
            try encodeInstructionPayload(versionMismatch, compressed: true),
            sequence: seq1
        )
        _ = await drainEventually(session: session)

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
        XCTAssertEqual(drained[0], .resize(cols: 120, rows: 40))
        XCTAssertEqual(drained[1], .echoAck(55))

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
}

private func defaultSnapshotEncoder(_ blob: SessionStateBlob) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(blob)
}

private enum EncodeSentinel: Error {
    case failure
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

private func encodeUInt64BE(_ value: UInt64) -> Data {
    var output = Data()
    for shift in stride(from: 56, through: 0, by: -8) {
        output.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
    return output
}

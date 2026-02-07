import Foundation
import Darwin
import Network
import XCTest
@testable import MoshTransport
@testable import MoshWire

final class TransportTests: XCTestCase {
    func testTransportClockAndAddressCodableHashable() throws {
        let now = TransportClock.nowMs()
        XCTAssertGreaterThan(now, 0)

        let address = UDPTransportEndpointAddress(host: "127.0.0.1", port: 60001)
        let encoded = try JSONEncoder().encode(address)
        let decoded = try JSONDecoder().decode(UDPTransportEndpointAddress.self, from: encoded)
        XCTAssertEqual(decoded, address)
    }

    func testInMemoryEndpointLifecycleAndDelivery() async throws {
        let (left, right) = await InMemoryDatagramPair.makeLinked()

        do {
            _ = try await left.receive()
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await left.start()
        try await right.start()

        do {
            try await left.start()
            XCTFail("Expected alreadyStarted")
        } catch {
            guard case .alreadyStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await left.send(Data([0x01, 0x02]))
        let datagram = try await right.receive()
        XCTAssertEqual(datagram.data, Data([0x01, 0x02]))

        let waiting = Task {
            try await right.receive()
        }
        await right.stop()

        do {
            _ = try await waiting.value
            XCTFail("Expected cancelled")
        } catch {
            guard let typed = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
            switch typed {
            case .cancelled, .notStarted:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await right.send(Data([0x03]))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInMemoryEndpointSendWithoutPeerThrowsNotStarted() async throws {
        let endpoint = InMemoryDatagramEndpoint()
        try await endpoint.start()

        do {
            try await endpoint.send(Data([0xAA]))
            XCTFail("Expected notStarted without peer")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNetworkEndpointPreStartAndInvalidPort() async {
        let endpoint = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: 9999))

        do {
            try await endpoint.send(Data([1]))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await endpoint.receive()
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let invalidPort = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: 0))
        do {
            try await invalidPort.start()
            XCTFail("Expected invalidPort")
        } catch {
            guard case .invalidPort(0) = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await endpoint.stop()
    }

    func testNetworkEndpointLoopbackAndAlreadyStartedAndStopCancellation() async throws {
        var portA = try reserveUDPPort()
        var portB = try reserveUDPPort()
        if portA == portB {
            portB = try reserveUDPPort()
        }
        if portA == portB {
            portA = try reserveUDPPort()
        }

        let endpointA = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: portB), localPort: portA)
        let endpointB = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: portA), localPort: portB)

        try await endpointA.start()
        try await endpointB.start()

        do {
            try await endpointA.start()
            XCTFail("Expected alreadyStarted")
        } catch {
            guard case .alreadyStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let waitFirst = Task { try await endpointB.receive() }
        try await endpointA.send(Data([0x99]))
        let first = try await waitFirst.value
        XCTAssertEqual(first.data, Data([0x99]))

        let waitSecond = Task { try await endpointB.receive() }
        await endpointB.stop()

        do {
            _ = try await waitSecond.value
            XCTFail("Expected cancelled")
        } catch {
            guard let typed = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
            switch typed {
            case .cancelled, .notStarted:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        await endpointA.stop()
    }

    func testNetworkEndpointDeterministicSendReceiveAndStopCoverage() async throws {
        let fake = FakeUDPConnection()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60001),
            connectionFactory: { _, _, _ in fake }
        )

        let startTask = Task { try await endpoint.start() }
        let hasStateHandler = await waitUntil { fake.hasStateHandler }
        XCTAssertTrue(hasStateHandler)
        try? await Task.sleep(nanoseconds: 2_000_000)
        fake.emitState(.ready)
        try await startTask.value
        let hasReceiveHandler = await waitUntil { fake.hasReceiveHandler }
        XCTAssertTrue(hasReceiveHandler)

        fake.emitReceive(content: Data([0xFA]), error: nil)
        let didRearmReceive = await waitUntil { fake.receiveRegistrationCount >= 2 }
        XCTAssertTrue(didRearmReceive)

        let buffered = try await endpoint.receive()
        XCTAssertEqual(buffered.data, Data([0xFA]))

        fake.sendError = .posix(.ECONNABORTED)
        do {
            try await endpoint.send(Data([0x01]))
            XCTFail("Expected sendFailure")
        } catch {
            guard case .sendFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        fake.sendError = nil

        let waitingOnError = Task { try await endpoint.receive() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        fake.emitReceive(content: nil, error: .posix(.ECONNRESET))
        do {
            _ = try await waitingOnError.value
            XCTFail("Expected networkFailure")
        } catch {
            guard case .networkFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        fake.emitReceive(content: nil, error: nil)
        try? await Task.sleep(nanoseconds: 2_000_000)

        let waitingOnStop = Task { try await endpoint.receive() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        await endpoint.stop()
        do {
            _ = try await waitingOnStop.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await endpoint._testArmReceiveLoop()
    }

    func testNetworkEndpointDeterministicStateFailureAndCancellationCoverage() async throws {
        let failedConnection = FakeUDPConnection()
        let failedEndpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60002),
            connectionFactory: { _, _, _ in failedConnection }
        )

        let failedStart = Task { try await failedEndpoint.start() }
        let failedReady = await waitUntil { failedConnection.hasStateHandler && failedConnection.startCallCount > 0 }
        XCTAssertTrue(failedReady)
        try? await Task.sleep(nanoseconds: 2_000_000)
        failedConnection.emitState(.failed(.posix(.ECONNREFUSED)))
        do {
            try await failedStart.value
            XCTFail("Expected networkFailure")
        } catch {
            guard case .networkFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let cancelledConnection = FakeUDPConnection()
        let cancelledEndpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60003),
            connectionFactory: { _, _, _ in cancelledConnection }
        )

        let cancelledStart = Task { try await cancelledEndpoint.start() }
        let cancelledReady = await waitUntil { cancelledConnection.hasStateHandler && cancelledConnection.startCallCount > 0 }
        XCTAssertTrue(cancelledReady)
        try? await Task.sleep(nanoseconds: 2_000_000)
        cancelledConnection.emitState(.ready)
        try await cancelledStart.value

        let waitingReceive = Task { try await cancelledEndpoint.receive() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        cancelledConnection.emitState(.cancelled)
        do {
            _ = try await waitingReceive.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTransportEngineSendReceiveSnapshotRestoreAndFiltering() async throws {
        setenv("SWIFTMOSH_DEBUG_REAL_E2E", "1", 1)
        defer { unsetenv("SWIFTMOSH_DEBUG_REAL_E2E") }

        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer, mtu: 40)

        try await engine.start()
        let seq0 = await engine.reserveOutgoingSequence()
        XCTAssertEqual(seq0, 0)

        let sendPayload = Data((0..<50).map(UInt8.init))
        try await engine.sendPayload(sendPayload, sequence: seq0)
        let sentCount = await endpoint.sentCount()
        XCTAssertGreaterThan(sentCount, 1)
        let sentDatagrams = await endpoint.sentDatagrams()
        let sentPackets = try sentDatagrams.map(MoshPacketCodec.decode)
        for (index, packet) in sentPackets.enumerated() {
            XCTAssertEqual(packet.sequence, UInt64(index))
        }

        var snapshot = await engine.makeSnapshot()
        XCTAssertEqual(snapshot.nextOutgoingSequence, UInt64(sentCount))
        XCTAssertEqual(snapshot.nextInstructionID, 1)
        XCTAssertNotNil(snapshot.lastSentAtMs)

        snapshot.expectedIncomingSequence = 3
        await engine.restore(from: snapshot)

        // wrong direction packet (toServer) should be skipped
        await endpoint.inject(datagramFromPacket(seq: 3, dir: .toServer, fragmentID: 1, fragmentNumber: 0, final: true, contents: Data([0xA0])))
        // stale packet (seq 2) should be skipped
        await endpoint.inject(datagramFromPacket(seq: 2, dir: .toClient, fragmentID: 1, fragmentNumber: 0, final: true, contents: Data([0xA1])))

        let fullPayload = Data([0x10, 0x11, 0x12, 0x13, 0x14])
        await endpoint.inject(datagramFromPacket(seq: 3, dir: .toClient, fragmentID: 7, fragmentNumber: 0, final: false, contents: Data(fullPayload.prefix(2))))
        await endpoint.inject(datagramFromPacket(seq: 3, dir: .toClient, fragmentID: 7, fragmentNumber: 1, final: true, contents: Data(fullPayload.suffix(3))))

        let received = try await engine.receivePayload()
        XCTAssertEqual(received.sequence, 3)
        XCTAssertEqual(received.direction, .toClient)
        XCTAssertEqual(received.payload, fullPayload)

        let restoredSnapshot = await engine.makeSnapshot()
        XCTAssertEqual(restoredSnapshot.expectedIncomingSequence, 4)
        XCTAssertNotNil(restoredSnapshot.lastReceivedAtMs)

        await engine.stop()
        let stopped = await endpoint.isStopped()
        XCTAssertTrue(stopped)
    }

    func testTransportEnginePropagatesMalformedDatagramError() async throws {
        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer)
        try await engine.start()

        await endpoint.inject(TransportDatagram(data: Data([0x01])))

        do {
            _ = try await engine.receivePayload()
            XCTFail("Expected wire decode failure")
        } catch {
            XCTAssertTrue(error is MoshWireError)
        }

        await engine.stop()
    }

    func testTransportEngineReceivePayloadWithDebugDisabled() async throws {
        unsetenv("SWIFTMOSH_DEBUG_REAL_E2E")

        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer, mtu: 128)
        try await engine.start()

        let payload = Data([0x55, 0x56, 0x57])
        await endpoint.inject(
            datagramFromPacket(
                seq: 0,
                dir: .toClient,
                fragmentID: 44,
                fragmentNumber: 0,
                final: true,
                contents: payload
            )
        )

        let received = try await engine.receivePayload()
        XCTAssertEqual(received.payload, payload)
        XCTAssertEqual(received.sequence, 0)
        await engine.stop()
    }

    func testTransportEngineReceivePayloadThrowsCancelledWhenTaskIsCancelled() async throws {
        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer)
        try await engine.start()

        let receiveTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.receivePayload()
        }

        do {
            _ = try await receiveTask.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await engine.stop()
    }

    private func datagramFromPacket(
        seq: UInt64,
        dir: MoshDirection,
        fragmentID: UInt64,
        fragmentNumber: UInt16,
        final: Bool,
        contents: Data
    ) -> TransportDatagram {
        let fragment = MoshFragment(id: fragmentID, fragmentNumber: fragmentNumber, final: final, contents: contents)
        let packet = MoshPacket(sequence: seq, direction: dir, timestamp: 1, timestampReply: UInt16.max, payload: fragment.encoded())
        return TransportDatagram(data: MoshPacketCodec.encode(packet), receivedAtMs: TransportClock.nowMs())
    }
}

private func reserveUDPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    guard nameResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    return UInt16(bigEndian: bound.sin_port)
}

private actor StubDatagramEndpoint: DatagramEndpoint {
    private(set) var started = false
    private(set) var stopped = false
    private var receiveQueue: [TransportDatagram] = []
    private var sent: [Data] = []

    func start() async throws {
        if started {
            throw TransportError.alreadyStarted
        }
        started = true
        stopped = false
    }

    func stop() async {
        stopped = true
        started = false
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
        guard !receiveQueue.isEmpty else {
            throw TransportError.cancelled
        }
        return receiveQueue.removeFirst()
    }

    func inject(_ datagram: TransportDatagram) {
        receiveQueue.append(datagram)
    }

    func sentCount() -> Int {
        sent.count
    }

    func sentDatagrams() -> [Data] {
        sent
    }

    func isStopped() -> Bool {
        stopped
    }
}

private final class FakeUDPConnection: UDPConnection, @unchecked Sendable {
    private let lock = NSLock()

    private var _stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    private var _receiveCompletion: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?

    private(set) var startCallCount: Int = 0
    private(set) var receiveRegistrationCount: Int = 0
    var sendError: NWError?

    var hasStateHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _stateUpdateHandler != nil
    }

    var hasReceiveHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _receiveCompletion != nil
    }

    func setStateUpdateHandler(_ handler: (@Sendable (NWConnection.State) -> Void)?) {
        lock.lock()
        _stateUpdateHandler = handler
        lock.unlock()
    }

    func start(queue: DispatchQueue) {
        lock.lock()
        startCallCount += 1
        lock.unlock()
    }

    func cancel() {}

    func send(content: Data?, completion: NWConnection.SendCompletion) {
        let error: NWError?
        lock.lock()
        error = sendError
        lock.unlock()

        if case .contentProcessed(let callback) = completion {
            callback(error)
        }
    }

    func receiveMessage(completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        lock.lock()
        _receiveCompletion = completion
        receiveRegistrationCount += 1
        lock.unlock()
    }

    func emitState(_ state: NWConnection.State) {
        let callback: (@Sendable (NWConnection.State) -> Void)?
        lock.lock()
        callback = _stateUpdateHandler
        lock.unlock()
        callback?(state)
    }

    func emitReceive(content: Data?, error: NWError?) {
        let callback: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
        lock.lock()
        callback = _receiveCompletion
        lock.unlock()
        callback?(content, nil, true, error)
    }
}

private func waitUntil(
    timeoutNs: UInt64 = 1_000_000_000,
    stepNs: UInt64 = 2_000_000,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    var waited: UInt64 = 0
    while waited < timeoutNs {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: stepNs)
        waited += stepNs
    }
    return condition()
}

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import SwiftMosh

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

    func testNIOEndpointPreStart() async {
        let endpoint = NIODatagramEndpoint(remote: .init(host: "127.0.0.1", port: 9999))

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

        await endpoint.stop()
    }

    func testNIOEndpointLoopbackAndAlreadyStartedAndStopCancellation() async throws {
        var portA = try reserveUDPPort()
        var portB = try reserveUDPPort()
        if portA == portB {
            portB = try reserveUDPPort()
        }
        if portA == portB {
            portA = try reserveUDPPort()
        }

        let endpointA = NIODatagramEndpoint(remote: .init(host: "127.0.0.1", port: portB), localPort: portA)
        let endpointB = NIODatagramEndpoint(remote: .init(host: "127.0.0.1", port: portA), localPort: portB)

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
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
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

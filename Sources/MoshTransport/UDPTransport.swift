import Foundation
import Network
import MoshWire

public struct UDPTransportEndpointAddress: Sendable, Hashable, Codable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct TransportDatagram: Sendable, Hashable, Codable {
    public var data: Data
    public var receivedAtMs: UInt64

    public init(data: Data, receivedAtMs: UInt64 = TransportClock.nowMs()) {
        self.data = data
        self.receivedAtMs = receivedAtMs
    }
}

public enum TransportError: Error, Sendable {
    case invalidPort(UInt16)
    case alreadyStarted
    case notStarted
    case cancelled
    case networkFailure(String)
    case sendFailure(String)
    case malformedDatagram
}

public enum TransportClock {
    public static func nowMs() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000)
    }
}

public protocol DatagramEndpoint: Sendable {
    func start() async throws
    func stop() async
    func send(_ data: Data) async throws
    func receive() async throws -> TransportDatagram
}

protocol UDPConnection: AnyObject {
    func setStateUpdateHandler(_ handler: (@Sendable (NWConnection.State) -> Void)?)
    func start(queue: DispatchQueue)
    func cancel()
    func send(content: Data?, completion: NWConnection.SendCompletion)
    func receiveMessage(completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)
}

final class NWUDPConnectionAdapter: UDPConnection {
    private let connection: NWConnection

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, parameters: NWParameters) {
        self.connection = NWConnection(host: host, port: port, using: parameters)
    }

    func setStateUpdateHandler(_ handler: (@Sendable (NWConnection.State) -> Void)?) {
        connection.stateUpdateHandler = handler
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(content: Data?, completion: NWConnection.SendCompletion) {
        connection.send(content: content, completion: completion)
    }

    func receiveMessage(completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        connection.receiveMessage(completion: completion)
    }
}

public actor NetworkDatagramEndpoint: DatagramEndpoint {
    private let remote: UDPTransportEndpointAddress
    private let localPort: UInt16?
    private let connectionFactory: (NWEndpoint.Host, NWEndpoint.Port, NWParameters) -> any UDPConnection
    private let queue = DispatchQueue(label: "swift.mosh.network.endpoint")

    private var connection: (any UDPConnection)?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var receiveContinuations: [CheckedContinuation<TransportDatagram, Error>] = []
    private var receiveBuffer: [TransportDatagram] = []

    public init(remote: UDPTransportEndpointAddress, localPort: UInt16? = nil) {
        self.init(remote: remote, localPort: localPort) { host, port, parameters in
            NWUDPConnectionAdapter(host: host, port: port, parameters: parameters)
        }
    }

    init(
        remote: UDPTransportEndpointAddress,
        localPort: UInt16? = nil,
        connectionFactory: @escaping (NWEndpoint.Host, NWEndpoint.Port, NWParameters) -> any UDPConnection
    ) {
        self.remote = remote
        self.localPort = localPort
        self.connectionFactory = connectionFactory
    }

    public func start() async throws {
        guard connection == nil else {
            throw TransportError.alreadyStarted
        }

        let remotePort = try makePort(remote.port)
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        if let localPort {
            let local = try makePort(localPort)
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: local)
        }

        let connection = connectionFactory(NWEndpoint.Host(remote.host), remotePort, parameters)
        self.connection = connection

        connection.setStateUpdateHandler { [weak self] state in
            guard let self else { return }
            Task { await self.handleConnectionState(state) }
        }

        connection.start(queue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
        }

        armReceiveLoop()
    }

    public func stop() async {
        connection?.cancel()
        connection = nil

        startContinuation?.resume(throwing: TransportError.cancelled)
        startContinuation = nil

        let continuations = receiveContinuations
        receiveContinuations.removeAll(keepingCapacity: false)
        receiveBuffer.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(throwing: TransportError.cancelled)
        }
    }

    public func send(_ data: Data) async throws {
        guard let connection else {
            throw TransportError.notStarted
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.sendFailure(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> TransportDatagram {
        guard connection != nil else {
            throw TransportError.notStarted
        }

        if let buffered = receiveBuffer.first {
            receiveBuffer.removeFirst()
            return buffered
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportDatagram, Error>) in
            receiveContinuations.append(continuation)
        }
    }

    private func makePort(_ port: UInt16) throws -> NWEndpoint.Port {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.invalidPort(port)
        }
        return endpointPort
    }

    private func armReceiveLoop() {
        guard let connection else { return }

        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            Task { await self.handleReceive(content: content, error: error) }
        }
    }

    private func handleReceive(content: Data?, error: NWError?) {
        defer { armReceiveLoop() }

        if let error {
            if let continuation = receiveContinuations.first {
                receiveContinuations.removeFirst()
                continuation.resume(throwing: TransportError.networkFailure(error.localizedDescription))
            }
            return
        }

        guard let content else {
            return
        }

        let datagram = TransportDatagram(data: content)
        if let continuation = receiveContinuations.first {
            receiveContinuations.removeFirst()
            continuation.resume(returning: datagram)
        } else {
            receiveBuffer.append(datagram)
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startContinuation?.resume()
            startContinuation = nil
        case .failed(let error):
            failAll(TransportError.networkFailure(error.localizedDescription))
        case .cancelled:
            failAll(TransportError.cancelled)
        default:
            break
        }
    }

    private func failAll(_ error: TransportError) {
        startContinuation?.resume(throwing: error)
        startContinuation = nil

        let continuations = receiveContinuations
        receiveContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func _testArmReceiveLoop() {
        armReceiveLoop()
    }
}

public actor InMemoryDatagramEndpoint: DatagramEndpoint {
    private var started = false
    private var peer: InMemoryDatagramEndpoint?
    private var inbox: [TransportDatagram] = []
    private var waiters: [CheckedContinuation<TransportDatagram, Error>] = []

    public init() {}

    public func start() async throws {
        guard !started else {
            throw TransportError.alreadyStarted
        }
        started = true
    }

    public func stop() async {
        started = false
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        inbox.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: TransportError.cancelled)
        }
    }

    public func send(_ data: Data) async throws {
        guard started else {
            throw TransportError.notStarted
        }
        guard let peer else {
            throw TransportError.notStarted
        }

        await peer.enqueue(TransportDatagram(data: data))
    }

    public func receive() async throws -> TransportDatagram {
        guard started else {
            throw TransportError.notStarted
        }

        if let queued = inbox.first {
            inbox.removeFirst()
            return queued
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportDatagram, Error>) in
            waiters.append(continuation)
        }
    }

    public func link(_ peer: InMemoryDatagramEndpoint) {
        self.peer = peer
    }

    private func enqueue(_ datagram: TransportDatagram) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: datagram)
        } else {
            inbox.append(datagram)
        }
    }
}

public enum InMemoryDatagramPair {
    public static func makeLinked() async -> (InMemoryDatagramEndpoint, InMemoryDatagramEndpoint) {
        let left = InMemoryDatagramEndpoint()
        let right = InMemoryDatagramEndpoint()
        await left.link(right)
        await right.link(left)
        return (left, right)
    }
}

public struct TransportRuntimeSnapshot: Sendable, Hashable, Codable {
    public var nextOutgoingSequence: UInt64
    public var expectedIncomingSequence: UInt64
    public var nextInstructionID: UInt64
    public var lastSentAtMs: UInt64?
    public var lastReceivedAtMs: UInt64?

    public init(
        nextOutgoingSequence: UInt64 = 0,
        expectedIncomingSequence: UInt64 = 0,
        nextInstructionID: UInt64 = 0,
        lastSentAtMs: UInt64? = nil,
        lastReceivedAtMs: UInt64? = nil
    ) {
        self.nextOutgoingSequence = nextOutgoingSequence
        self.expectedIncomingSequence = expectedIncomingSequence
        self.nextInstructionID = nextInstructionID
        self.lastSentAtMs = lastSentAtMs
        self.lastReceivedAtMs = lastReceivedAtMs
    }
}

public struct TransportReceivedPayload: Sendable, Hashable, Codable {
    public var sequence: UInt64
    public var direction: MoshDirection
    public var timestamp: UInt16
    public var timestampReply: UInt16
    public var payload: Data

    public init(sequence: UInt64, direction: MoshDirection, timestamp: UInt16, timestampReply: UInt16, payload: Data) {
        self.sequence = sequence
        self.direction = direction
        self.timestamp = timestamp
        self.timestampReply = timestampReply
        self.payload = payload
    }
}

public actor TransportEngine {
    private let endpoint: any DatagramEndpoint
    private let outgoingDirection: MoshDirection
    private let mtu: Int

    private var fragmenter: MoshFragmenter
    private var assembly: MoshFragmentAssembly
    private var snapshot: TransportRuntimeSnapshot
    private let debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"

    public init(endpoint: any DatagramEndpoint, outgoingDirection: MoshDirection, mtu: Int = 1200) {
        self.endpoint = endpoint
        self.outgoingDirection = outgoingDirection
        self.mtu = mtu
        self.fragmenter = MoshFragmenter()
        self.assembly = MoshFragmentAssembly()
        self.snapshot = TransportRuntimeSnapshot()
    }

    public func start() async throws {
        try await endpoint.start()
    }

    public func stop() async {
        await endpoint.stop()
        assembly.reset()
    }

    public func reserveOutgoingSequence() -> UInt64 {
        let value = snapshot.nextOutgoingSequence
        snapshot.nextOutgoingSequence &+= 1
        return value
    }

    public func sendPayload(_ payload: Data, sequence: UInt64) async throws {
        let messageID = snapshot.nextInstructionID
        snapshot.nextInstructionID &+= 1

        let fragments = try fragmenter.makeFragments(messageID: messageID, encodedInstruction: payload, mtu: mtu - MoshWire.packetHeaderBytes)
        let timestamp = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        var currentSequence = sequence

        for index in fragments.indices {
            let fragment = fragments[index]
            let packet = MoshPacket(
                sequence: currentSequence,
                direction: outgoingDirection,
                timestamp: timestamp,
                timestampReply: UInt16.max,
                payload: fragment.encoded()
            )
            try await endpoint.send(MoshPacketCodec.encode(packet))

            if index != fragments.index(before: fragments.endIndex) {
                currentSequence = snapshot.nextOutgoingSequence
                snapshot.nextOutgoingSequence &+= 1
            }
        }

        snapshot.lastSentAtMs = TransportClock.nowMs()
    }

    public func receivePayload() async throws -> TransportReceivedPayload {
        while !Task.isCancelled {
            let datagram = try await endpoint.receive()
            snapshot.lastReceivedAtMs = datagram.receivedAtMs

            let packet = try MoshPacketCodec.decode(datagram.data)
            if debugEnabled {
                debugLog("recv packet seq=\(packet.sequence) dir=\(packet.direction) payload=\(packet.payload.count)")
            }

            if packet.sequence < snapshot.expectedIncomingSequence {
                if debugEnabled {
                    debugLog("drop stale packet seq=\(packet.sequence) expected=\(snapshot.expectedIncomingSequence)")
                }
                continue
            }

            let expectedIncomingDirection: MoshDirection = outgoingDirection == .toServer ? .toClient : .toServer
            if packet.direction != expectedIncomingDirection {
                if debugEnabled {
                    debugLog("drop direction packet dir=\(packet.direction) expected=\(expectedIncomingDirection)")
                }
                continue
            }

            let fragment = try MoshFragment(decoding: packet.payload)
            if debugEnabled {
                debugLog("fragment id=\(fragment.id) num=\(fragment.fragmentNumber) final=\(fragment.final) size=\(fragment.contents.count)")
            }
            let isComplete = assembly.add(fragment)
            guard isComplete else {
                if debugEnabled {
                    debugLog("assembly incomplete")
                }
                continue
            }

            let payload = try assembly.assembled()
            snapshot.expectedIncomingSequence = packet.sequence &+ 1
            if debugEnabled {
                debugLog("assembly complete payload=\(payload.count) nextExpected=\(snapshot.expectedIncomingSequence)")
            }
            return TransportReceivedPayload(
                sequence: packet.sequence,
                direction: packet.direction,
                timestamp: packet.timestamp,
                timestampReply: packet.timestampReply,
                payload: payload
            )
        }

        throw TransportError.cancelled
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[TransportEngine] \(message)\n".utf8))
    }

    public func makeSnapshot() -> TransportRuntimeSnapshot {
        snapshot
    }

    public func restore(from snapshot: TransportRuntimeSnapshot) {
        self.snapshot = snapshot
        self.assembly.reset()
    }
}

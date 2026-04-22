import Foundation

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

import Foundation

public struct MoshEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: UInt16
    public var keyBase64_22: String

    public init(host: String, port: UInt16, keyBase64_22: String) {
        self.host = host
        self.port = port
        self.keyBase64_22 = keyBase64_22
    }
}

public struct MoshClientConfig: Sendable, Hashable, Codable {
    public var sendMinDelayMs: UInt32
    public var maxReceiveStates: Int
    public var ackIntervalMs: UInt32
    public var ackDelayMs: UInt32
    public var networkTimeoutMs: UInt32
    public var maxRetransmitCount: UInt32
    public var initialRtoMs: UInt32
    public var maxRtoMs: UInt32
    public var heartbeatIntervalMs: UInt32
    public var mtu: Int
    public var localPort: UInt16?
    public var useNetworkCrypto: Bool

    public init(
        sendMinDelayMs: UInt32 = 8,
        maxReceiveStates: Int = 1024,
        ackIntervalMs: UInt32 = 3000,
        ackDelayMs: UInt32 = 100,
        networkTimeoutMs: UInt32 = 30_000,
        maxRetransmitCount: UInt32 = 32,
        initialRtoMs: UInt32 = 600,
        maxRtoMs: UInt32 = 4_000,
        heartbeatIntervalMs: UInt32 = 3_000,
        mtu: Int = 1200,
        localPort: UInt16? = nil,
        useNetworkCrypto: Bool = true
    ) {
        self.sendMinDelayMs = sendMinDelayMs
        self.maxReceiveStates = max(1, maxReceiveStates)
        self.ackIntervalMs = ackIntervalMs
        self.ackDelayMs = ackDelayMs
        self.networkTimeoutMs = max(500, networkTimeoutMs)
        self.maxRetransmitCount = max(1, maxRetransmitCount)
        self.initialRtoMs = max(50, initialRtoMs)
        self.maxRtoMs = max(self.initialRtoMs, maxRtoMs)
        self.heartbeatIntervalMs = max(250, heartbeatIntervalMs)
        self.mtu = max(128, mtu)
        self.localPort = localPort
        self.useNetworkCrypto = useNetworkCrypto
    }
}

public struct MoshSnapshot: Sendable, Hashable, Codable {
    public var endpoint: MoshEndpoint
    public var transportState: Data
    public var createdAtMs: UInt64
    public var schemaVersion: UInt16

    public init(endpoint: MoshEndpoint, transportState: Data, createdAtMs: UInt64, schemaVersion: UInt16 = 1) {
        self.endpoint = endpoint
        self.transportState = transportState
        self.createdAtMs = createdAtMs
        self.schemaVersion = schemaVersion
    }
}

public enum MoshHostOp: Sendable, Hashable, Codable {
    case hostBytes(Data)
    case resize(cols: Int32, rows: Int32)
    case echoAck(UInt64)
}

public enum MoshClientOp: Sendable, Hashable, Codable {
    case keystrokes(Data)
    case resize(cols: Int32, rows: Int32)
}

public protocol MoshHostOpSink: Sendable {
    func apply(hostOps: [MoshHostOp]) async
}

public enum MoshSessionError: Error, Sendable {
    case invalidEndpoint
    case notStarted
    case badSnapshotSchema(UInt16)
    case decodeFailure
    case encodeFailure
    case sessionFailed(MoshSessionFailure)
}

struct SessionStateBlob: Sendable, Codable, Hashable {
    var config: MoshClientConfig
    var pendingHostOps: [MoshHostOp]
    var transportSnapshot: MoshSessionContextSnapshot
}

public enum MoshSessionState: Sendable, Hashable, Codable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed(MoshSessionFailure)
}

public enum MoshSessionFailure: Sendable, Hashable, Codable, Error {
    case timeout(timeoutMs: UInt32)
    case protocolViolation(String)
    case authenticationFailure(String)
    case retryLimitExceeded(stateNum: UInt64, retryCount: UInt32)
    case circuitBreakerTripped(consecutiveFailures: UInt32, message: String)
    case transportFailure(String)
}

import Foundation
import MoshTransport

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
    public var mtu: Int
    public var localPort: UInt16?
    public var useNetworkCrypto: Bool

    public init(
        sendMinDelayMs: UInt32 = 8,
        maxReceiveStates: Int = 1024,
        ackIntervalMs: UInt32 = 3000,
        ackDelayMs: UInt32 = 100,
        mtu: Int = 1200,
        localPort: UInt16? = nil,
        useNetworkCrypto: Bool = true
    ) {
        self.sendMinDelayMs = sendMinDelayMs
        self.maxReceiveStates = max(1, maxReceiveStates)
        self.ackIntervalMs = ackIntervalMs
        self.ackDelayMs = ackDelayMs
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
}

struct SessionStateBlob: Sendable, Codable, Hashable {
    var config: MoshClientConfig
    var transport: TransportRuntimeSnapshot
    var pendingHostOps: [MoshHostOp]
}

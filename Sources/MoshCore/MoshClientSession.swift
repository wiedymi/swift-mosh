import Foundation
import MoshCompression
import MoshCryptoOCB
import MoshProtoLite
import MoshTransport
import MoshWire

public actor MoshClientSession {
    private let endpointFactory: @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint
    private let snapshotEncoder: @Sendable (SessionStateBlob) throws -> Data

    private(set) public var endpoint: MoshEndpoint
    private(set) public var config: MoshClientConfig

    private var engine: TransportEngine?
    private var receiveTask: Task<Void, Never>?

    private var pendingHostOps: [MoshHostOp] = []
    private var pendingTransportSnapshot: TransportRuntimeSnapshot?

    private var lastSentStateNum: UInt64 = 0
    private let debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"

    public init(endpoint: MoshEndpoint, config: MoshClientConfig = .init()) {
        self.endpoint = endpoint
        self.config = config
        self.endpointFactory = { endpoint, config in
            NetworkDatagramEndpoint(
                remote: UDPTransportEndpointAddress(host: endpoint.host, port: endpoint.port),
                localPort: config.localPort
            )
        }
        self.snapshotEncoder = Self.defaultSnapshotEncoder
    }

    init(
        endpoint: MoshEndpoint,
        config: MoshClientConfig,
        endpointFactory: @escaping @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint,
        snapshotEncoder: @escaping @Sendable (SessionStateBlob) throws -> Data
    ) {
        self.endpoint = endpoint
        self.config = config
        self.endpointFactory = endpointFactory
        self.snapshotEncoder = snapshotEncoder
    }

    public func start() async throws {
        if engine != nil {
            return
        }

        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw MoshSessionError.invalidEndpoint
        }

        let key = try MoshBase64Key(printableKey: endpoint.keyBase64_22)

        let endpointImpl = endpointFactory(endpoint, config)
        let runtimeEndpoint: any DatagramEndpoint
        if config.useNetworkCrypto {
            runtimeEndpoint = try MoshEncryptedDatagramEndpoint(wrapping: endpointImpl, key: key.raw)
        } else {
            runtimeEndpoint = endpointImpl
        }

        let engine = TransportEngine(endpoint: runtimeEndpoint, outgoingDirection: .toServer, mtu: config.mtu)
        try await engine.start()

        if let pendingTransportSnapshot {
            await engine.restore(from: pendingTransportSnapshot)
            self.pendingTransportSnapshot = nil
        }

        self.engine = engine
        self.receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func stop() async {
        receiveTask?.cancel()
        receiveTask = nil

        if let engine {
            await engine.stop()
        }
        engine = nil
    }

    public func enqueue(_ op: MoshClientOp) async throws {
        guard let engine else {
            throw MoshSessionError.notStarted
        }

        let diff = try encodeUserDiff(from: op)
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: lastSentStateNum &+ 1,
            diff: diff,
            chaff: Data()
        )
        let encodedInstruction = instruction.encoded()
        let compressed = try MoshCompressionCodec().compress(encodedInstruction, algorithm: .zlib)

        let sequence = await engine.reserveOutgoingSequence()
        try await engine.sendPayload(compressed, sequence: sequence)
        lastSentStateNum &+= 1
    }

    public func drainHostOps() async -> [MoshHostOp] {
        let drained = pendingHostOps
        pendingHostOps.removeAll(keepingCapacity: true)
        return drained
    }

    public func makeSnapshot() async throws -> MoshSnapshot {
        let runtimeSnapshot = await engine?.makeSnapshot() ?? pendingTransportSnapshot ?? TransportRuntimeSnapshot()
        let blob = SessionStateBlob(config: config, transport: runtimeSnapshot, pendingHostOps: pendingHostOps)

        let stateData: Data
        do {
            stateData = try snapshotEncoder(blob)
        } catch {
            throw MoshSessionError.encodeFailure
        }

        return MoshSnapshot(
            endpoint: endpoint,
            transportState: stateData,
            createdAtMs: TransportClock.nowMs(),
            schemaVersion: 1
        )
    }

    public static func restore(from snapshot: MoshSnapshot, config: MoshClientConfig = .init()) async throws -> MoshClientSession {
        guard snapshot.schemaVersion == 1 else {
            throw MoshSessionError.badSnapshotSchema(snapshot.schemaVersion)
        }

        let blob: SessionStateBlob
        do {
            blob = try JSONDecoder().decode(SessionStateBlob.self, from: snapshot.transportState)
        } catch {
            throw MoshSessionError.decodeFailure
        }

        let effectiveConfig = config == MoshClientConfig() ? blob.config : config
        let session = MoshClientSession(endpoint: snapshot.endpoint, config: effectiveConfig)
        await session.install(blob: blob)
        return session
    }

    private func install(blob: SessionStateBlob) {
        pendingHostOps = blob.pendingHostOps
        pendingTransportSnapshot = blob.transport
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            if await !runReceiveLoopIteration() {
                break
            }
        }
    }

    private static func defaultSnapshotEncoder(_ blob: SessionStateBlob) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(blob)
    }

    private func runReceiveLoopIteration() async -> Bool {
        do {
            guard let engine else {
                return false
            }
            let incoming = try await engine.receivePayload()
            let hostOps = try decodeHostOps(from: incoming)
            if !hostOps.isEmpty {
                pendingHostOps.append(contentsOf: hostOps)
                if pendingHostOps.count > config.maxReceiveStates {
                    let overflow = pendingHostOps.count - config.maxReceiveStates
                    pendingHostOps.removeFirst(overflow)
                }
            }
        } catch {
            if debugEnabled {
                debugLog("receive loop iteration error: \(error)")
            }
            if Task.isCancelled {
                return false
            }
        }
        return true
    }

    func _testRunReceiveLoopIteration() async -> Bool {
        await runReceiveLoopIteration()
    }

    private func encodeUserDiff(from op: MoshClientOp) throws -> Data {
        switch op {
        case .keystrokes(let bytes):
            return UserMessage(instructions: [.keystroke(bytes)]).encoded()
        case .resize(let cols, let rows):
            return UserMessage(instructions: [.resize(width: cols, height: rows)]).encoded()
        }
    }

    private func decodeHostOps(from incoming: TransportReceivedPayload) throws -> [MoshHostOp] {
        guard !incoming.payload.isEmpty else {
            return []
        }

        let decompressed = try? MoshCompressionCodec().decompress(incoming.payload, algorithm: .zlib)
        let instructionBytes = decompressed ?? incoming.payload
        if debugEnabled {
            debugLog(
                "decodeHostOps payloadLen=\(incoming.payload.count) decompressedLen=\(decompressed?.count ?? -1) instructionLen=\(instructionBytes.count)"
            )
        }

        let instruction: TransportInstruction
        do {
            instruction = try TransportInstruction(decoding: instructionBytes)
        } catch {
            if debugEnabled {
                debugLog("TransportInstruction decode error: \(error)")
            }
            throw error
        }
        if debugEnabled {
            debugLog(
                "incoming seq=\(incoming.sequence) dir=\(incoming.direction) proto=\(String(describing: instruction.protocolVersion)) old=\(String(describing: instruction.oldNum)) new=\(String(describing: instruction.newNum)) ack=\(String(describing: instruction.ackNum)) throw=\(String(describing: instruction.throwawayNum)) diff=\(instruction.diff?.count ?? 0) chaff=\(instruction.chaff?.count ?? 0)"
            )
        }

        if let version = instruction.protocolVersion, version != MoshWire.protocolVersion {
            if debugEnabled {
                debugLog("dropping incoming due protocol mismatch: \(version)")
            }
            return []
        }

        guard let diff = instruction.diff else {
            if debugEnabled {
                debugLog("dropping incoming with no diff")
            }
            return []
        }

        if let hostMessage = try? HostMessage(decoding: diff) {
            if debugEnabled {
                debugLog("decoded HostMessage instructionCount=\(hostMessage.instructions.count)")
            }
            return hostMessage.instructions.map { instruction in
                switch instruction {
                case .hostBytes(let bytes):
                    return .hostBytes(bytes)
                case .resize(let width, let height):
                    return .resize(cols: width, rows: height)
                case .echoAck(let value):
                    return .echoAck(value)
                }
            }
        }

        if debugEnabled {
            debugLog("HostMessage decode failed, using fallback hostBytes diffLen=\(diff.count)")
        }
        return [.hostBytes(diff)]
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshClientSession] \(message)\n".utf8))
    }
}

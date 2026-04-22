import Foundation
import NIOCore
import NIOPosix

enum SessionRuntimeError: Error, Sendable {
    case fatal(MoshSessionFailure)
}

public actor MoshClientSession {
    private(set) public var endpoint: MoshEndpoint
    private(set) public var config: MoshClientConfig
    private(set) public var state: MoshSessionState = .idle
    private(set) public var failure: MoshSessionFailure?

    private var channel: Channel?
    private let group: EventLoopGroup

    private var receiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    private var sessionContext: MoshSessionContext?
    private var pendingTransportSnapshot: MoshSessionContextSnapshot?

    private var pendingHostOps: [MoshHostOp] = []

    private var lastInboundAtMs: UInt64 = 0

    private var consecutiveReceiveFailures: UInt32 = 0
    private let consecutiveFailureLimit: UInt32 = 8

    private var hostStreamContinuations: [UUID: AsyncStream<MoshHostOp>.Continuation] = [:]
    private var inboundContinuation: AsyncStream<MoshSessionEvent>.Continuation?

    private let debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"

    public init(endpoint: MoshEndpoint, config: MoshClientConfig = .init()) {
        self.endpoint = endpoint
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func start() async throws {
        if case .running = state { return }
        if case .starting = state { return }
        if case .failed(let reason) = state {
            throw MoshSessionError.sessionFailed(reason)
        }

        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw MoshSessionError.invalidEndpoint
        }

        state = .starting

        do {
            let key = try MoshBase64Key(printableKey: endpoint.keyBase64_22)
            let remoteAddress = try SocketAddress(ipAddress: endpoint.host, port: Int(endpoint.port))

            let (stream, continuation) = AsyncStream.makeStream(of: MoshSessionEvent.self)
            self.inboundContinuation = continuation

            let context = MoshSessionContext(config: config)
            if let pendingTransportSnapshot {
                context.restore(from: pendingTransportSnapshot)
                self.pendingTransportSnapshot = nil
            }
            self.sessionContext = context

            let bootstrap = DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.initializeMoshContext(context)
                    return channel.pipeline.addHandlers([
                        OCBEncryptHandler(key: key.raw, remoteAddress: remoteAddress),
                        MoshPacketEncoder(),
                        MoshFrameEncoder(mtu: config.mtu, outgoingDirection: .toServer),
                        MoshPayloadEncoder(),
                        OCBDecryptHandler(key: key.raw),
                        MoshPacketDecoder(),
                        MoshFrameDecoder(),
                        MoshPayloadDecoder(),
                        MoshProtocolHandler(),
                        MoshRetransmitHandler(),
                        MoshThrottleHandler(),
                        MoshEventHandler(onEvent: { event in
                            continuation.yield(event)
                        })
                    ])
                }

            let bindPort = Int(config.localPort ?? 0)
            let channel = try await bootstrap.bind(host: "0.0.0.0", port: bindPort).get()
            self.channel = channel

            let now = TransportClock.nowMs()
            lastInboundAtMs = now
            consecutiveReceiveFailures = 0

            state = .running
            self.receiveTask = Task {
                await receiveLoop(from: stream)
            }
            self.maintenanceTask = Task {
                await maintenanceLoop()
            }
        } catch {
            state = .idle
            throw error
        }
    }

    public func stop() async {
        state = .stopping
        await shutdownRuntime()
        state = .stopped
    }

    public func enqueue(_ op: MoshClientOp) async throws {
        guard case .running = state else {
            if case .failed(let reason) = state {
                throw MoshSessionError.sessionFailed(reason)
            }
            throw MoshSessionError.notStarted
        }

        let diff = try encodeUserDiff(from: op)
        let lastSent = sessionContext?.lastSentStateNum ?? 0
        let stateNum = lastSent &+ 1
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSent,
            newNum: stateNum,
            ackNum: sessionContext?.latestReceivedStateNum ?? 0,
            throwawayNum: sessionContext?.pendingOutboundStateNums().first ?? 0,
            diff: diff,
            chaff: Data()
        )

        try await sendInstruction(instruction)
    }

    public func drainHostOps() async -> [MoshHostOp] {
        let drained = pendingHostOps
        pendingHostOps.removeAll(keepingCapacity: true)
        return drained
    }

    public func hostOpStream() -> AsyncStream<MoshHostOp> {
        let streamID = UUID()
        return AsyncStream(MoshHostOp.self, bufferingPolicy: .unbounded) { continuation in
            for op in self.pendingHostOps {
                continuation.yield(op)
            }
            self.hostStreamContinuations[streamID] = continuation
            continuation.onTermination = { [streamID] _ in
                Task {
                    await self.removeHostStreamContinuation(streamID)
                }
            }
        }
    }

    public func makeSnapshot() async throws -> MoshSnapshot {
        let transportSnapshot = sessionContext?.makeSnapshot() ?? MoshSessionContextSnapshot()
        let blob = SessionStateBlob(config: config, pendingHostOps: pendingHostOps, transportSnapshot: transportSnapshot)

        let stateData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            stateData = try encoder.encode(blob)
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
        await session.install(pendingHostOps: blob.pendingHostOps, transportSnapshot: blob.transportSnapshot)
        return session
    }

    private func install(pendingHostOps: [MoshHostOp], transportSnapshot: MoshSessionContextSnapshot? = nil) {
        self.pendingHostOps = pendingHostOps
        self.pendingTransportSnapshot = transportSnapshot
    }

    private func receiveLoop(from stream: AsyncStream<MoshSessionEvent>) async {
        for await event in stream {
            guard !Task.isCancelled else { break }
            switch event {
            case .hostOps(let hostOps):
                lastInboundAtMs = TransportClock.nowMs()
                consecutiveReceiveFailures = 0
                if !hostOps.isEmpty {
                    publishHostOps(hostOps)
                }
            case .error(let error):
                if Task.isCancelled || state == .stopping || state == .stopped {
                    break
                }
                let disposition = classifyReceiveError(error)
                switch disposition {
                case .fatal(let reason):
                    await failSession(reason)
                    return
                case .transient(let delayMs, let message):
                    consecutiveReceiveFailures &+= 1
                    if debugEnabled {
                        debugLog("transient receive error (\(consecutiveReceiveFailures)): \(message)")
                    }
                    if consecutiveReceiveFailures >= consecutiveFailureLimit {
                        await failSession(
                            .circuitBreakerTripped(
                                consecutiveFailures: consecutiveReceiveFailures,
                                message: message
                            )
                        )
                        return
                    }
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
            }
        }
    }

    private func maintenanceLoop() async {
        while !Task.isCancelled {
            guard case .running = state else { return }

            let now = TransportClock.nowMs()
            if now > lastInboundAtMs,
               now - lastInboundAtMs > UInt64(config.networkTimeoutMs)
            {
                await failSession(.timeout(timeoutMs: config.networkTimeoutMs))
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func encodeUserDiff(from op: MoshClientOp) throws -> Data {
        switch op {
        case .keystrokes(let bytes):
            return UserMessage(instructions: [.keystroke(bytes)]).encoded()
        case .resize(let cols, let rows):
            return UserMessage(instructions: [.resize(width: cols, height: rows)]).encoded()
        }
    }

    private func sendInstruction(_ instruction: TransportInstruction) async throws {
        guard let channel else {
            throw MoshSessionError.notStarted
        }
        try await channel.writeAndFlush(NIOAny(instruction)).get()
    }

    private func publishHostOps(_ hostOps: [MoshHostOp]) {
        pendingHostOps.append(contentsOf: hostOps)
        if pendingHostOps.count > config.maxReceiveStates {
            let overflow = pendingHostOps.count - config.maxReceiveStates
            pendingHostOps.removeFirst(overflow)
        }

        for op in hostOps {
            for continuation in hostStreamContinuations.values {
                continuation.yield(op)
            }
        }
    }

    private func removeHostStreamContinuation(_ streamID: UUID) {
        hostStreamContinuations.removeValue(forKey: streamID)
    }

    private func finishHostStreams() {
        let continuations = hostStreamContinuations.values
        hostStreamContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func shutdownRuntime() async {
        receiveTask?.cancel()
        maintenanceTask?.cancel()
        receiveTask = nil
        maintenanceTask = nil
        inboundContinuation?.finish()
        inboundContinuation = nil

        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        try? await group.shutdownGracefully().get()
        finishHostStreams()
    }

    private func failSession(_ failure: MoshSessionFailure) async {
        if case .failed = state {
            return
        }
        self.failure = failure
        state = .failed(failure)
        await shutdownRuntime()
    }

    private enum ReceiveErrorDisposition {
        case transient(delayMs: UInt64, message: String)
        case fatal(MoshSessionFailure)
    }

    private func classifyReceiveError(_ error: Error) -> ReceiveErrorDisposition {
        if let runtime = error as? SessionRuntimeError {
            switch runtime {
            case .fatal(let failure):
                return .fatal(failure)
            }
        }

        if let transport = error as? TransportError {
            switch transport {
            case .networkFailure(let message), .sendFailure(let message):
                let delay = min(1_000, UInt64(50) << min(6, consecutiveReceiveFailures))
                return .transient(delayMs: delay, message: message)
            case .cancelled:
                return .fatal(.transportFailure("cancelled"))
            default:
                return .fatal(.transportFailure("\(transport)"))
            }
        }

        if let crypto = error as? OCBCipherError {
            return .fatal(.authenticationFailure("\(crypto)"))
        }

        if error is ProtoLiteError || error is MoshWireError {
            return .fatal(.protocolViolation("\(error)"))
        }

        let delay = min(1_000, UInt64(50) << min(6, consecutiveReceiveFailures))
        return .transient(delayMs: delay, message: "\(error)")
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshClientSession] \(message)\n".utf8))
    }
}

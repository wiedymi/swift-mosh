import Foundation
import NIOCore
import NIOPosix

public actor MoshClientSession {
    private struct PendingOutboundInstruction: Sendable {
        var stateNum: UInt64
        var instruction: TransportInstruction
        var retryCount: UInt32
        var lastSentAtMs: UInt64
        var nextRetryAtMs: UInt64
    }

    private enum SessionRuntimeError: Error, Sendable {
        case fatal(MoshSessionFailure)
    }

    private(set) public var endpoint: MoshEndpoint
    private(set) public var config: MoshClientConfig
    private(set) public var state: MoshSessionState = .idle
    private(set) public var failure: MoshSessionFailure?

    private var channel: Channel?
    private let group: EventLoopGroup

    private var receiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    private var pendingHostOps: [MoshHostOp] = []

    private var lastSentStateNum: UInt64 = 0
    private var latestReceivedStateNum: UInt64 = 0

    private var pendingOutbound: [UInt64: PendingOutboundInstruction] = [:]
    private var pendingOutboundOrder: [UInt64] = []

    private var lastInboundAtMs: UInt64 = 0
    private var lastOutboundAtMs: UInt64 = 0
    private var lastStateSendAtMs: UInt64 = 0

    private var ackDirtyAtMs: UInt64?
    private var lastAckSentAtMs: UInt64 = 0
    private var lastAckReportedNum: UInt64 = 0

    private var srttMs: Double?
    private var rttvarMs: Double?
    private var currentRtoMs: Double

    private var appliedRemoteStateNums: Set<UInt64> = []

    private var consecutiveReceiveFailures: UInt32 = 0
    private let consecutiveFailureLimit: UInt32 = 8

    private var hostStreamContinuations: [UUID: AsyncStream<MoshHostOp>.Continuation] = [:]
    private var inboundContinuation: AsyncStream<MoshInboundEnvelope>.Continuation?

    private let debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"

    public init(endpoint: MoshEndpoint, config: MoshClientConfig = .init()) {
        self.endpoint = endpoint
        self.config = config
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.currentRtoMs = Double(config.initialRtoMs)
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

            let (stream, continuation) = AsyncStream.makeStream(of: MoshInboundEnvelope.self)
            self.inboundContinuation = continuation

            let bootstrap = DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        OCBDecryptHandler(key: key.raw),
                        MoshPacketDecoder(),
                        MoshFrameDecoder(),
                        MoshPayloadDecoder(),
                        MoshDeliveryHandler(onEnvelope: { envelope in
                            continuation.yield(envelope)
                        }),
                        MoshPayloadEncoder(),
                        MoshFrameEncoder(mtu: config.mtu, outgoingDirection: .toServer),
                        MoshPacketEncoder(),
                        OCBEncryptHandler(key: key.raw, remoteAddress: remoteAddress)
                    ])
                }

            let bindPort = Int(config.localPort ?? 0)
            let channel = try await bootstrap.bind(host: "0.0.0.0", port: bindPort).get()
            self.channel = channel

            let now = TransportClock.nowMs()
            lastInboundAtMs = now
            lastOutboundAtMs = now
            lastStateSendAtMs = 0
            lastAckSentAtMs = now
            ackDirtyAtMs = nil
            consecutiveReceiveFailures = 0
            currentRtoMs = Double(config.initialRtoMs)
            srttMs = nil
            rttvarMs = nil

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

        try await applySendMinDelayIfNeeded()

        let diff = try encodeUserDiff(from: op)
        let stateNum = lastSentStateNum &+ 1
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: stateNum,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: diff,
            chaff: Data()
        )

        try await sendInstruction(instruction)

        let now = TransportClock.nowMs()
        let pending = PendingOutboundInstruction(
            stateNum: stateNum,
            instruction: instruction,
            retryCount: 0,
            lastSentAtMs: now,
            nextRetryAtMs: now &+ UInt64(currentRtoClampedMs())
        )
        pendingOutbound[stateNum] = pending
        pendingOutboundOrder.append(stateNum)
        lastSentStateNum = stateNum
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
        let blob = SessionStateBlob(config: config, pendingHostOps: pendingHostOps)

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
        await session.install(pendingHostOps: blob.pendingHostOps)
        return session
    }

    private func install(pendingHostOps: [MoshHostOp]) {
        self.pendingHostOps = pendingHostOps
    }

    private func receiveLoop(from stream: AsyncStream<MoshInboundEnvelope>) async {
        for await envelope in stream {
            guard !Task.isCancelled else { break }
            do {
                try await processInbound(envelope)
            } catch {
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

            do {
                try await processRetransmitQueue(nowMs: now)
                try await maybeSendAck(nowMs: now)
                try await maybeSendHeartbeat(nowMs: now)
            } catch let SessionRuntimeError.fatal(failure) {
                await failSession(failure)
                return
            } catch {
                await failSession(.transportFailure("\(error)"))
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func processInbound(_ envelope: MoshInboundEnvelope) async throws {
        let instruction = envelope.instruction
        lastInboundAtMs = TransportClock.nowMs()
        updateRtt(timestampReply: envelope.timestampReply)

        let hostOps = try decodeHostOps(from: instruction)
        consecutiveReceiveFailures = 0

        if !hostOps.isEmpty {
            publishHostOps(hostOps)
        }

        if ackDirtyAtMs != nil, latestReceivedStateNum > lastAckReportedNum {
            try? await sendAckOnly(nowMs: TransportClock.nowMs())
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

    private func decodeHostOps(from instruction: TransportInstruction) throws -> [MoshHostOp] {
        if let version = instruction.protocolVersion, version != MoshWire.protocolVersion {
            throw SessionRuntimeError.fatal(.protocolViolation("mosh protocol mismatch: got \(version)"))
        }

        if let ack = instruction.ackNum {
            acknowledgePendingOutbound(through: ack)
        }
        if let throwaway = instruction.throwawayNum, throwaway > 0 {
            pruneAppliedRemoteStates(before: throwaway)
        }

        if let newNum = instruction.newNum {
            if appliedRemoteStateNums.contains(newNum) {
                return []
            }
            if let oldNum = instruction.oldNum, oldNum > latestReceivedStateNum {
                return []
            }
            latestReceivedStateNum = max(latestReceivedStateNum, newNum)
            appliedRemoteStateNums.insert(newNum)
            if appliedRemoteStateNums.count > 4096 {
                let floor = latestReceivedStateNum > 2048 ? latestReceivedStateNum - 2048 : 0
                appliedRemoteStateNums = Set(appliedRemoteStateNums.filter { $0 >= floor })
            }
            ackDirtyAtMs = TransportClock.nowMs()
        }

        guard let diff = instruction.diff else {
            return []
        }

        if let hostMessage = try? HostMessage(decoding: diff), !hostMessage.instructions.isEmpty {
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

        return [.hostBytes(diff)]
    }

    private func updateRtt(timestampReply: UInt16) {
        guard timestampReply != UInt16.max else { return }
        let now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        let sample = Double(MoshWire.timestampDiff(new: now16, old: timestampReply))
        applyRttSample(sample)
    }

    private func applyRttSample(_ sample: Double) {
        guard sample > 0, sample < 5_000 else { return }

        if srttMs == nil {
            srttMs = sample
            rttvarMs = sample / 2
        } else {
            let alpha = 1.0 / 8.0
            let beta = 1.0 / 4.0
            let oldSrtt = srttMs!
            let oldRttvar = rttvarMs ?? (sample / 2)
            rttvarMs = ((1 - beta) * oldRttvar) + (beta * abs(oldSrtt - sample))
            srttMs = ((1 - alpha) * oldSrtt) + (alpha * sample)
        }

        let srtt = srttMs!
        let rttvar = rttvarMs!
        let candidate = srtt + max(10, 4 * rttvar)
        currentRtoMs = min(
            Double(config.maxRtoMs),
            max(Double(config.initialRtoMs), candidate)
        )
    }

    private func acknowledgePendingOutbound(through ackNum: UInt64) {
        let acknowledged = pendingOutboundOrder.filter { $0 <= ackNum }
        guard !acknowledged.isEmpty else { return }

        for stateNum in acknowledged {
            pendingOutbound.removeValue(forKey: stateNum)
        }
        pendingOutboundOrder.removeAll { $0 <= ackNum }
    }

    private func pruneAppliedRemoteStates(before throwawayNum: UInt64) {
        guard throwawayNum > 0 else { return }
        appliedRemoteStateNums = Set(appliedRemoteStateNums.filter { $0 >= throwawayNum })
    }

    private func processRetransmitQueue(nowMs: UInt64) async throws {
        for stateNum in pendingOutboundOrder {
            guard var pending = pendingOutbound[stateNum] else { continue }
            guard nowMs >= pending.nextRetryAtMs else { continue }

            if pending.retryCount >= config.maxRetransmitCount {
                throw SessionRuntimeError.fatal(
                    .retryLimitExceeded(
                        stateNum: stateNum,
                        retryCount: pending.retryCount
                    )
                )
            }

            try await sendInstruction(pending.instruction)
            pending.retryCount &+= 1
            pending.lastSentAtMs = nowMs
            pending.nextRetryAtMs = nowMs &+ UInt64(currentRtoClampedMs())
            pendingOutbound[stateNum] = pending
        }
    }

    private func maybeSendAck(nowMs: UInt64) async throws {
        guard let ackDirtyAtMs else {
            if nowMs >= lastAckSentAtMs,
               nowMs - lastAckSentAtMs >= UInt64(config.ackIntervalMs),
               latestReceivedStateNum > lastAckReportedNum
            {
                try await sendAckOnly(nowMs: nowMs)
            }
            return
        }

        let delayElapsed = nowMs >= ackDirtyAtMs && (nowMs - ackDirtyAtMs >= UInt64(config.ackDelayMs))
        let intervalElapsed = nowMs >= lastAckSentAtMs && (nowMs - lastAckSentAtMs >= UInt64(config.ackIntervalMs))
        if delayElapsed || intervalElapsed {
            try await sendAckOnly(nowMs: nowMs)
        }
    }

    private func maybeSendHeartbeat(nowMs: UInt64) async throws {
        guard nowMs >= lastOutboundAtMs else { return }
        guard nowMs - lastOutboundAtMs >= UInt64(config.heartbeatIntervalMs) else { return }

        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: lastSentStateNum,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: nil,
            chaff: Data()
        )
        try await sendInstruction(instruction)
        lastAckSentAtMs = nowMs
        lastAckReportedNum = latestReceivedStateNum
        ackDirtyAtMs = nil
    }

    private func sendAckOnly(nowMs: UInt64) async throws {
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSentStateNum,
            newNum: lastSentStateNum,
            ackNum: latestReceivedStateNum,
            throwawayNum: computeThrowawayNum(),
            diff: nil,
            chaff: Data()
        )
        try await sendInstruction(instruction)
        lastAckSentAtMs = nowMs
        lastAckReportedNum = latestReceivedStateNum
        ackDirtyAtMs = nil
    }

    private func applySendMinDelayIfNeeded() async throws {
        guard config.sendMinDelayMs > 0 else { return }
        guard lastStateSendAtMs > 0 else {
            lastStateSendAtMs = TransportClock.nowMs()
            return
        }

        let now = TransportClock.nowMs()
        let elapsed = now >= lastStateSendAtMs ? now - lastStateSendAtMs : 0
        if elapsed < UInt64(config.sendMinDelayMs) {
            let sleepMs = UInt64(config.sendMinDelayMs) - elapsed
            try await Task.sleep(nanoseconds: sleepMs * 1_000_000)
        }
        lastStateSendAtMs = TransportClock.nowMs()
    }

    private func sendInstruction(_ instruction: TransportInstruction) async throws {
        guard let channel else {
            throw MoshSessionError.notStarted
        }
        try await channel.writeAndFlush(NIOAny(instruction)).get()
        lastOutboundAtMs = TransportClock.nowMs()
    }

    private func computeThrowawayNum() -> UInt64 {
        pendingOutboundOrder.first ?? 0
    }

    private func currentRtoClampedMs() -> UInt32 {
        let rounded = UInt32(max(1, Int(currentRtoMs.rounded())))
        return min(config.maxRtoMs, max(config.initialRtoMs, rounded))
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

struct SessionStateBlob: Sendable, Codable, Hashable {
    var config: MoshClientConfig
    var pendingHostOps: [MoshHostOp]
}

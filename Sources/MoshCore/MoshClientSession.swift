import Foundation
import MoshCompression
import MoshCryptoOCB
import MoshProtoLite
import MoshTransport
import MoshWire

public actor MoshClientSession {
    private struct PendingOutboundInstruction: Sendable {
        var stateNum: UInt64
        var payload: Data
        var retryCount: UInt32
        var lastSentAtMs: UInt64
        var nextRetryAtMs: UInt64
    }

    private enum SessionRuntimeError: Error, Sendable {
        case fatal(MoshSessionFailure)
    }

    private let endpointFactory: @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint
    private let snapshotEncoder: @Sendable (SessionStateBlob) throws -> Data

    private(set) public var endpoint: MoshEndpoint
    private(set) public var config: MoshClientConfig
    private(set) public var state: MoshSessionState = .idle
    private(set) public var failure: MoshSessionFailure?

    private var engine: TransportEngine?
    private var receiveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    private var pendingHostOps: [MoshHostOp] = []
    private var pendingTransportSnapshot: TransportRuntimeSnapshot?

    private var lastSentStateNum: UInt64 = 0
    private var latestReceivedStateNum: UInt64 = 0

    private var pendingOutbound: [UInt64: PendingOutboundInstruction] = [:]
    private var pendingOutboundOrder: [UInt64] = []

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

    private var hostStreamContinuations: [UUID: AsyncStream<MoshHostOp>.Continuation] = [:]

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
        self.currentRtoMs = Double(config.initialRtoMs)
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
        self.currentRtoMs = Double(config.initialRtoMs)
    }

    public func start() async throws {
        if case .running = state {
            return
        }
        if case .starting = state {
            return
        }
        if case .suspending = state {
            throw MoshSessionError.notStarted
        }
        if case .suspended = state {
            throw MoshSessionError.notStarted
        }
        if case .failed(let reason) = state {
            throw MoshSessionError.sessionFailed(reason)
        }

        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw MoshSessionError.invalidEndpoint
        }

        state = .starting

        do {
            let engine = try makeTransportEngine()
            try await engine.start()

            if let pendingTransportSnapshot {
                await engine.restore(from: pendingTransportSnapshot)
                self.pendingTransportSnapshot = nil
            }

            self.engine = engine
            let now = TransportClock.nowMs()
            lastOutboundAtMs = now
            lastStateSendAtMs = 0
            lastAckSentAtMs = now
            ackDirtyAtMs = latestReceivedStateNum > lastAckReportedNum ? now : nil
            consecutiveReceiveFailures = 0
            currentRtoMs = Double(config.initialRtoMs)
            srttMs = nil
            rttvarMs = nil

            state = .running
            self.receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            self.maintenanceTask = Task { [weak self] in
                await self?.maintenanceLoop()
            }
        } catch {
            state = .idle
            throw error
        }
    }

    public func stop() async {
        state = .stopping
        await shutdownRuntime()
        pendingTransportSnapshot = nil
        state = .stopped
    }

    public func prepareForApplicationBackground() async throws -> MoshSnapshot {
        switch state {
        case .running:
            state = .suspending
            await suspendRuntime()
            state = .suspended
            return try await makeSnapshot()
        case .suspended:
            return try await makeSnapshot()
        case .failed(let failure):
            throw MoshSessionError.sessionFailed(failure)
        case .idle, .starting, .suspending, .stopping, .stopped:
            throw MoshSessionError.notStarted
        }
    }

    public func resumeFromApplicationBackground() async throws {
        switch state {
        case .running:
            return
        case .suspended:
            state = .idle
            try await start()
        case .failed(let failure):
            throw MoshSessionError.sessionFailed(failure)
        case .idle, .starting, .suspending, .stopping, .stopped:
            throw MoshSessionError.notStarted
        }
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

        let payload = try encodeInstruction(instruction)
        try await sendPayload(payload)

        let now = TransportClock.nowMs()
        let pending = PendingOutboundInstruction(
            stateNum: stateNum,
            payload: payload,
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
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHostStreamContinuation(streamID) }
            }
        }
    }

    public func makeSnapshot() async throws -> MoshSnapshot {
        let runtimeSnapshot = await engine?.makeSnapshot() ?? pendingTransportSnapshot ?? TransportRuntimeSnapshot()
        let outboundSnapshots = pendingOutboundOrder.compactMap { stateNum in
            pendingOutbound[stateNum].map {
                PendingOutboundSnapshot(
                    stateNum: $0.stateNum,
                    payload: $0.payload,
                    retryCount: $0.retryCount
                )
            }
        }
        let blob = SessionStateBlob(
            config: config,
            transport: runtimeSnapshot,
            pendingHostOps: pendingHostOps,
            lastSentStateNum: lastSentStateNum,
            latestReceivedStateNum: latestReceivedStateNum,
            pendingOutbound: outboundSnapshots,
            lastAckReportedNum: lastAckReportedNum,
            appliedRemoteStateNums: appliedRemoteStateNums
        )

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
            schemaVersion: 2
        )
    }

    public static func restore(from snapshot: MoshSnapshot, config: MoshClientConfig = .init()) async throws -> MoshClientSession {
        try await restore(
            from: snapshot,
            config: config,
            endpointFactory: { endpoint, config in
                NetworkDatagramEndpoint(
                    remote: UDPTransportEndpointAddress(
                        host: endpoint.host,
                        port: endpoint.port
                    ),
                    localPort: config.localPort
                )
            },
            snapshotEncoder: Self.defaultSnapshotEncoder
        )
    }

    static func restore(
        from snapshot: MoshSnapshot,
        config: MoshClientConfig = .init(),
        endpointFactory: @escaping @Sendable (MoshEndpoint, MoshClientConfig) -> any DatagramEndpoint,
        snapshotEncoder: @escaping @Sendable (SessionStateBlob) throws -> Data
    ) async throws -> MoshClientSession {
        guard (1...2).contains(snapshot.schemaVersion) else {
            throw MoshSessionError.badSnapshotSchema(snapshot.schemaVersion)
        }

        let blob: SessionStateBlob
        do {
            blob = try JSONDecoder().decode(SessionStateBlob.self, from: snapshot.transportState)
        } catch {
            throw MoshSessionError.decodeFailure
        }

        let effectiveConfig = config == MoshClientConfig() ? blob.config : config
        let session = MoshClientSession(
            endpoint: snapshot.endpoint,
            config: effectiveConfig,
            endpointFactory: endpointFactory,
            snapshotEncoder: snapshotEncoder
        )
        await session.install(blob: blob)
        return session
    }

    private func install(blob: SessionStateBlob) {
        pendingHostOps = blob.pendingHostOps
        pendingTransportSnapshot = blob.transport
        lastSentStateNum = blob.lastSentStateNum
        latestReceivedStateNum = blob.latestReceivedStateNum
        lastAckReportedNum = blob.lastAckReportedNum
        appliedRemoteStateNums = blob.appliedRemoteStateNums

        let now = TransportClock.nowMs()
        pendingOutbound = Dictionary(
            uniqueKeysWithValues: blob.pendingOutbound.map { snapshot in
                (
                    snapshot.stateNum,
                    PendingOutboundInstruction(
                        stateNum: snapshot.stateNum,
                        payload: snapshot.payload,
                        retryCount: snapshot.retryCount,
                        lastSentAtMs: now,
                        nextRetryAtMs: now &+ UInt64(config.initialRtoMs)
                    )
                )
            }
        )
        pendingOutboundOrder = blob.pendingOutbound.map(\.stateNum)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            if await !runReceiveLoopIteration() {
                break
            }
        }
    }

    private func maintenanceLoop() async {
        while !Task.isCancelled {
            guard await runMaintenanceLoopIteration() else { return }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runMaintenanceLoopIteration() async -> Bool {
        guard case .running = state else { return false }

        let now = TransportClock.nowMs()
        do {
            try await processRetransmitQueue(nowMs: now)
            try await maybeSendAck(nowMs: now)
            try await maybeSendHeartbeat(nowMs: now)
            return true
        } catch let SessionRuntimeError.fatal(failure) {
            await failSession(failure)
            return false
        } catch {
            if !isRecoverableTransportError(error), engine != nil {
                await failSession(.transportFailure("\(error)"))
                return false
            }
            if debugEnabled {
                debugLog("maintenance paused for transient transport error: \(error)")
            }
            return true
        }
    }

    private static func defaultSnapshotEncoder(_ blob: SessionStateBlob) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(blob)
    }

    private func runReceiveLoopIteration() async -> Bool {
        guard let engine else {
            return state == .running && !Task.isCancelled
        }

        do {
            let incoming = try await engine.receivePayload()
            updateRtt(from: incoming)

            let hostOps = try decodeHostOps(from: incoming)
            consecutiveReceiveFailures = 0

            if !hostOps.isEmpty {
                publishHostOps(hostOps)
            }

            if ackDirtyAtMs != nil, latestReceivedStateNum > lastAckReportedNum {
                try? await sendAckOnly(nowMs: TransportClock.nowMs())
            }
        } catch {
            if Task.isCancelled || state == .stopping || state == .stopped {
                return false
            }

            let disposition = classifyReceiveError(error)
            switch disposition {
            case .fatal(let reason):
                await failSession(reason)
                return false
            case .transient(let delayMs, let message):
                if consecutiveReceiveFailures < UInt32.max {
                    consecutiveReceiveFailures += 1
                }
                if debugEnabled {
                    debugLog("transient receive error (\(consecutiveReceiveFailures)): \(message)")
                }
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                guard !Task.isCancelled, state == .running else { return false }
                return await restartTransport(after: engine)
            }
        }
        return true
    }

    private func makeTransportEngine() throws -> TransportEngine {
        let key = try MoshBase64Key(printableKey: endpoint.keyBase64_22)
        let endpointImpl = endpointFactory(endpoint, config)
        let cipher: OCBTransportCipher? = config.useNetworkCrypto
            ? try OCBTransportCipher(key: key.raw)
            : nil
        return TransportEngine(
            endpoint: endpointImpl,
            outgoingDirection: .toServer,
            mtu: config.mtu,
            cipher: cipher
        )
    }

    private func restartTransport(after failedEngine: TransportEngine) async -> Bool {
        guard state == .running, engine === failedEngine else {
            return state == .running && engine != nil
        }

        let snapshot = await failedEngine.makeSnapshot()
        guard state == .running, engine === failedEngine else {
            return state == .running && engine != nil
        }

        engine = nil
        await failedEngine.stop()

        var retryDelayMs: UInt64 = 50
        while state == .running, !Task.isCancelled {
            do {
                let replacement = try makeTransportEngine()
                try await replacement.start()
                await replacement.restore(from: snapshot)
                guard state == .running, !Task.isCancelled else {
                    await replacement.stop()
                    return false
                }
                engine = replacement
                lastOutboundAtMs = TransportClock.nowMs()
                return true
            } catch {
                if debugEnabled {
                    debugLog("transport restart failed: \(error)")
                }
                try? await Task.sleep(nanoseconds: retryDelayMs * 1_000_000)
                retryDelayMs = min(1_000, retryDelayMs * 2)
            }
        }
        return false
    }

    func _testRunReceiveLoopIteration() async -> Bool {
        await runReceiveLoopIteration()
    }

    func _testPendingOutboundCount() -> Int {
        pendingOutbound.count
    }

    func _testCurrentRtoMs() -> UInt32 {
        currentRtoClampedMs()
    }

    func _testDecodeHostOps(
        instruction: TransportInstruction,
        compressed: Bool = true,
        timestampReply: UInt16 = UInt16.max
    ) throws -> [MoshHostOp] {
        let payload: Data
        if compressed {
            payload = try MoshCompressionCodec().compress(instruction.encoded(), algorithm: .zlib)
        } else {
            payload = instruction.encoded()
        }
        return try decodeHostOps(
            from: TransportReceivedPayload(
                sequence: 0,
                direction: .toClient,
                timestamp: 0,
                timestampReply: timestampReply,
                payload: payload
            )
        )
    }

    func _testClassifyReceiveError(_ error: Error) -> MoshSessionFailure? {
        switch classifyReceiveError(error) {
        case .fatal(let failure):
            return failure
        case .transient:
            return nil
        }
    }

    func _testApplyRttSample(_ sample: Double) {
        applyRttSample(sample)
    }

    func _testSetRttState(srttMs: Double?, rttvarMs: Double?) {
        self.srttMs = srttMs
        self.rttvarMs = rttvarMs
    }

    func _testUpdateRtt(timestampReply: UInt16) {
        updateRtt(
            from: TransportReceivedPayload(
                sequence: 0,
                direction: .toClient,
                timestamp: 0,
                timestampReply: timestampReply,
                payload: Data()
            )
        )
    }

    func _testInstructionHasContent(_ instruction: TransportInstruction) -> Bool {
        instructionHasContent(instruction)
    }

    func _testAcknowledgePendingOutbound(through ackNum: UInt64) {
        acknowledgePendingOutbound(through: ackNum)
    }

    func _testPruneAppliedRemoteStates(before throwawayNum: UInt64) {
        pruneAppliedRemoteStates(before: throwawayNum)
    }

    func _testSetAppliedRemoteStates(_ states: Set<UInt64>, latestReceivedStateNum: UInt64) {
        self.appliedRemoteStateNums = states
        self.latestReceivedStateNum = latestReceivedStateNum
    }

    func _testSeedPendingOutboundOrderWithoutPayload(stateNum: UInt64) {
        pendingOutboundOrder = [stateNum]
        pendingOutbound.removeAll(keepingCapacity: false)
    }

    func _testSetAckState(
        latestReceivedStateNum: UInt64,
        lastAckReportedNum: UInt64,
        lastAckSentAtMs: UInt64,
        ackDirtyAtMs: UInt64?
    ) {
        self.latestReceivedStateNum = latestReceivedStateNum
        self.lastAckReportedNum = lastAckReportedNum
        self.lastAckSentAtMs = lastAckSentAtMs
        self.ackDirtyAtMs = ackDirtyAtMs
    }

    func _testSetLastStateSendAtMs(_ value: UInt64) {
        lastStateSendAtMs = value
    }

    func _testSetLastOutboundAtMs(_ value: UInt64) {
        lastOutboundAtMs = value
    }

    func _testRunProcessRetransmitQueue(nowMs: UInt64) async throws {
        try await processRetransmitQueue(nowMs: nowMs)
    }

    func _testRunMaybeSendAck(nowMs: UInt64) async throws {
        try await maybeSendAck(nowMs: nowMs)
    }

    func _testRunMaybeSendHeartbeat(nowMs: UInt64) async throws {
        try await maybeSendHeartbeat(nowMs: nowMs)
    }

    func _testApplySendMinDelayIfNeeded() async throws {
        try await applySendMinDelayIfNeeded()
    }

    func _testFailSession(_ failure: MoshSessionFailure) async {
        await failSession(failure)
    }

    func _testSendPayload(_ payload: Data) async throws {
        try await sendPayload(payload)
    }

    func _testSetStateForMaintenanceCoverage(
        state: MoshSessionState,
        lastOutboundAtMs: UInt64,
        lastAckSentAtMs: UInt64,
        latestReceivedStateNum: UInt64,
        lastAckReportedNum: UInt64,
        ackDirtyAtMs: UInt64?
    ) {
        self.state = state
        self.lastOutboundAtMs = lastOutboundAtMs
        self.lastAckSentAtMs = lastAckSentAtMs
        self.latestReceivedStateNum = latestReceivedStateNum
        self.lastAckReportedNum = lastAckReportedNum
        self.ackDirtyAtMs = ackDirtyAtMs
        self.engine = nil
    }

    func _testRunMaintenanceLoopForCoverage() async {
        _ = await runMaintenanceLoopIteration()
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

        let codec = MoshCompressionCodec()
        let decompressed = try? codec.decompress(incoming.payload, algorithm: .zlib)
        let instructionBytes: Data
        let instruction: TransportInstruction
        if let decompressed,
           let candidate = try? TransportInstruction(decoding: decompressed),
           instructionHasContent(candidate)
        {
            instructionBytes = decompressed
            instruction = candidate
        } else {
            instructionBytes = incoming.payload
            instruction = try TransportInstruction(decoding: instructionBytes)
        }
        if debugEnabled {
            debugLog(
                "decodeHostOps payloadLen=\(incoming.payload.count) decompressedLen=\(decompressed?.count ?? -1) instructionLen=\(instructionBytes.count)"
            )
        }

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

    private func instructionHasContent(_ instruction: TransportInstruction) -> Bool {
        instruction.protocolVersion != nil ||
            instruction.oldNum != nil ||
            instruction.newNum != nil ||
            instruction.ackNum != nil ||
            instruction.throwawayNum != nil ||
            instruction.diff != nil ||
            instruction.chaff != nil
    }

    private func updateRtt(from incoming: TransportReceivedPayload) {
        guard incoming.timestampReply != UInt16.max else {
            return
        }

        let now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        let sample = Double(MoshWire.timestampDiff(new: now16, old: incoming.timestampReply))
        applyRttSample(sample)
    }

    private func applyRttSample(_ sample: Double) {
        guard sample > 0, sample < 5_000 else {
            return
        }

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

            try await sendPayload(pending.payload)
            if pending.retryCount < config.maxRetransmitCount {
                pending.retryCount += 1
            }
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
        try await sendPayload(try encodeInstruction(instruction))
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
        try await sendPayload(try encodeInstruction(instruction))
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

    private func sendPayload(_ payload: Data) async throws {
        guard let engine else {
            throw MoshSessionError.notStarted
        }
        try await engine.sendPayload(payload)
        lastOutboundAtMs = TransportClock.nowMs()
    }

    private func encodeInstruction(_ instruction: TransportInstruction) throws -> Data {
        let encodedInstruction = instruction.encoded()
        return try MoshCompressionCodec().compress(encodedInstruction, algorithm: .zlib)
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

        if let engine {
            await engine.stop()
        }
        engine = nil
        finishHostStreams()
    }

    private func suspendRuntime() async {
        receiveTask?.cancel()
        maintenanceTask?.cancel()
        receiveTask = nil
        maintenanceTask = nil

        guard let activeEngine = engine else { return }
        await activeEngine.stop()
        pendingTransportSnapshot = await activeEngine.makeSnapshot()
        if engine === activeEngine {
            engine = nil
        }
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
            case .cancelled, .notStarted:
                let delay = min(1_000, UInt64(50) << min(6, consecutiveReceiveFailures))
                return .transient(delayMs: delay, message: "\(transport)")
            case .invalidPort, .alreadyStarted, .malformedDatagram:
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

    private func isRecoverableTransportError(_ error: Error) -> Bool {
        guard let transport = error as? TransportError else { return false }
        switch transport {
        case .networkFailure, .sendFailure, .cancelled, .notStarted:
            return true
        case .invalidPort, .alreadyStarted, .malformedDatagram:
            return false
        }
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshClientSession] \(message)\n".utf8))
    }
}

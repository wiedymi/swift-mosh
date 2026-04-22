import Foundation
import NIOCore

// MARK: - Channel Attribute

private let moshSessionContextKey = AttributeKey<MoshSessionContext>("moshSessionContext")

extension Channel {
    var moshContext: MoshSessionContext? {
        self.attr(moshSessionContextKey).get()
    }

    func initializeMoshContext(_ context: MoshSessionContext) {
        self.attr(moshSessionContextKey).set(context)
    }
}

// MARK: - Snapshot

public struct MoshSessionContextSnapshot: Sendable, Codable, Hashable {
    public var nextOutgoingSequence: UInt64
    public var expectedIncomingSequence: UInt64
    public var nextInstructionID: UInt64
    public var lastSentStateNum: UInt64
    public var latestReceivedStateNum: UInt64
    public var appliedRemoteStateNums: [UInt64]
    public var srttMs: Double?
    public var rttvarMs: Double?
    public var currentRtoMs: Double
    public var lastSentAtMs: UInt64?
    public var lastReceivedAtMs: UInt64?
    public var pendingOutbound: [PendingOutboundInstruction]
    public var pendingOutboundOrder: [UInt64]

    public init(
        nextOutgoingSequence: UInt64 = 0,
        expectedIncomingSequence: UInt64 = 0,
        nextInstructionID: UInt64 = 0,
        lastSentStateNum: UInt64 = 0,
        latestReceivedStateNum: UInt64 = 0,
        appliedRemoteStateNums: [UInt64] = [],
        srttMs: Double? = nil,
        rttvarMs: Double? = nil,
        currentRtoMs: Double = 0,
        lastSentAtMs: UInt64? = nil,
        lastReceivedAtMs: UInt64? = nil,
        pendingOutbound: [PendingOutboundInstruction] = [],
        pendingOutboundOrder: [UInt64] = []
    ) {
        self.nextOutgoingSequence = nextOutgoingSequence
        self.expectedIncomingSequence = expectedIncomingSequence
        self.nextInstructionID = nextInstructionID
        self.lastSentStateNum = lastSentStateNum
        self.latestReceivedStateNum = latestReceivedStateNum
        self.appliedRemoteStateNums = appliedRemoteStateNums
        self.srttMs = srttMs
        self.rttvarMs = rttvarMs
        self.currentRtoMs = currentRtoMs
        self.lastSentAtMs = lastSentAtMs
        self.lastReceivedAtMs = lastReceivedAtMs
        self.pendingOutbound = pendingOutbound
        self.pendingOutboundOrder = pendingOutboundOrder
    }
}

// MARK: - Context

public struct PendingOutboundInstruction: Sendable {
    public var stateNum: UInt64
    public var instruction: TransportInstruction
    public var retryCount: UInt32
    public var lastSentAtMs: UInt64
    public var nextRetryAtMs: UInt64
}

public final class MoshSessionContext: @unchecked Sendable {
    private let lock = NSLock()

    // Transport sequence state
    public private(set) var nextOutgoingSequence: UInt64 = 0
    public private(set) var expectedIncomingSequence: UInt64 = 0
    public private(set) var nextInstructionID: UInt64 = 0
    public private(set) var lastSentAtMs: UInt64?
    public private(set) var lastReceivedAtMs: UInt64?

    // Protocol state
    public private(set) var lastSentStateNum: UInt64 = 0
    public private(set) var latestReceivedStateNum: UInt64 = 0
    public private(set) var appliedRemoteStateNums: Set<UInt64> = []

    // RTT state
    public private(set) var srttMs: Double?
    public private(set) var rttvarMs: Double?
    public private(set) var currentRtoMs: Double

    // Pending outbound queue
    private var pendingOutbound: [UInt64: PendingOutboundInstruction] = [:]
    private var pendingOutboundOrder: [UInt64] = []

    public let config: MoshClientConfig

    public init(config: MoshClientConfig) {
        self.config = config
        self.currentRtoMs = Double(config.initialRtoMs)
    }

    // MARK: - Sequence Reservations

    public func reserveOutgoingSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextOutgoingSequence
        nextOutgoingSequence &+= 1
        return value
    }

    public func reserveInstructionID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextInstructionID
        nextInstructionID &+= 1
        return value
    }

    // MARK: - Transport Updates

    public func recordSent() {
        lock.lock()
        defer { lock.unlock() }
        lastSentAtMs = TransportClock.nowMs()
    }

    public func recordReceived() {
        lock.lock()
        defer { lock.unlock() }
        lastReceivedAtMs = TransportClock.nowMs()
    }

    public func advanceExpectedIncomingSequence(to sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        expectedIncomingSequence = sequence
    }

    // MARK: - Protocol State

    public func isStateAlreadyApplied(_ stateNum: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return appliedRemoteStateNums.contains(stateNum)
    }

    public func isOldNumTooFarAhead(_ oldNum: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return oldNum > latestReceivedStateNum
    }

    public func applyRemoteStateNum(_ stateNum: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        latestReceivedStateNum = max(latestReceivedStateNum, stateNum)
        appliedRemoteStateNums.insert(stateNum)
        if appliedRemoteStateNums.count > 4096 {
            let floor = latestReceivedStateNum > 2048 ? latestReceivedStateNum - 2048 : 0
            appliedRemoteStateNums = Set(appliedRemoteStateNums.filter { $0 >= floor })
        }
    }

    public func pruneAppliedRemoteStates(before throwawayNum: UInt64) {
        guard throwawayNum > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        appliedRemoteStateNums = Set(appliedRemoteStateNums.filter { $0 >= throwawayNum })
    }

    public func updateLastSentStateNum(_ stateNum: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        lastSentStateNum = stateNum
    }

    // MARK: - RTT

    public func applyRttSample(_ sample: Double) {
        guard sample > 0, sample < 5_000 else { return }
        lock.lock()
        defer { lock.unlock() }

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

    public func currentRtoClampedMs() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let rounded = UInt32(max(1, Int(currentRtoMs.rounded())))
        return min(config.maxRtoMs, max(config.initialRtoMs, rounded))
    }

    // MARK: - Pending Outbound Queue

    public func enqueuePendingOutbound(_ pending: PendingOutboundInstruction) {
        lock.lock()
        defer { lock.unlock() }
        pendingOutbound[pending.stateNum] = pending
        pendingOutboundOrder.append(pending.stateNum)
    }

    public func acknowledgePendingOutbound(through ackNum: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let acknowledged = pendingOutboundOrder.filter { $0 <= ackNum }
        guard !acknowledged.isEmpty else { return }
        for stateNum in acknowledged {
            pendingOutbound.removeValue(forKey: stateNum)
        }
        pendingOutboundOrder.removeAll { $0 <= ackNum }
    }

    public func peekNextRetransmit(nowMs: UInt64) -> PendingOutboundInstruction? {
        lock.lock()
        defer { lock.unlock() }
        for stateNum in pendingOutboundOrder {
            if let pending = pendingOutbound[stateNum], nowMs >= pending.nextRetryAtMs {
                return pending
            }
        }
        return nil
    }

    public func recordRetransmit(stateNum: UInt64, nowMs: UInt64, nextRetryAtMs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard var pending = pendingOutbound[stateNum] else { return }
        pending.retryCount &+= 1
        pending.lastSentAtMs = nowMs
        pending.nextRetryAtMs = nextRetryAtMs
        pendingOutbound[stateNum] = pending
    }

    public func pendingOutboundCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingOutboundOrder.count
    }

    public func pendingOutboundStateNums() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return pendingOutboundOrder
    }

    // MARK: - Snapshot

    public func makeSnapshot() -> MoshSessionContextSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MoshSessionContextSnapshot(
            nextOutgoingSequence: nextOutgoingSequence,
            expectedIncomingSequence: expectedIncomingSequence,
            nextInstructionID: nextInstructionID,
            lastSentStateNum: lastSentStateNum,
            latestReceivedStateNum: latestReceivedStateNum,
            appliedRemoteStateNums: Array(appliedRemoteStateNums),
            srttMs: srttMs,
            rttvarMs: rttvarMs,
            currentRtoMs: currentRtoMs,
            lastSentAtMs: lastSentAtMs,
            lastReceivedAtMs: lastReceivedAtMs,
            pendingOutbound: Array(pendingOutbound.values),
            pendingOutboundOrder: pendingOutboundOrder
        )
    }

    public func restore(from snapshot: MoshSessionContextSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        nextOutgoingSequence = snapshot.nextOutgoingSequence
        expectedIncomingSequence = snapshot.expectedIncomingSequence
        nextInstructionID = snapshot.nextInstructionID
        lastSentStateNum = snapshot.lastSentStateNum
        latestReceivedStateNum = snapshot.latestReceivedStateNum
        appliedRemoteStateNums = Set(snapshot.appliedRemoteStateNums)
        srttMs = snapshot.srttMs
        rttvarMs = snapshot.rttvarMs
        currentRtoMs = snapshot.currentRtoMs
        lastSentAtMs = snapshot.lastSentAtMs
        lastReceivedAtMs = snapshot.lastReceivedAtMs
        pendingOutbound = Dictionary(uniqueKeysWithValues: snapshot.pendingOutbound.map { ($0.stateNum, $0) })
        pendingOutboundOrder = snapshot.pendingOutboundOrder
    }
}

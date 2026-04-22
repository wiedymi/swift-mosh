import Foundation

public protocol TransportCipher: Sendable {
    func seal(directionalSequence: UInt64, plaintext: Data) throws -> Data
    func open(datagram: Data) throws -> (directionalSequence: UInt64, plaintext: Data)
}

struct OCBTransportCipher: TransportCipher {
    private let cipher: OCBCipher

    init(key: Data) throws {
        self.cipher = try OCBCipher(key: key)
    }

    func seal(directionalSequence: UInt64, plaintext: Data) throws -> Data {
        let nonce = OCBNonce.from(messageID: 0, sequence: directionalSequence)
        let sealed = try cipher.seal(plaintext: plaintext, nonce: nonce)

        var out = Data(capacity: 8 + sealed.ciphertext.count + sealed.tag.count)
        out.appendBigEndian(directionalSequence)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    func open(datagram: Data) throws -> (directionalSequence: UInt64, plaintext: Data) {
        guard datagram.count >= 8 + 16 else {
            throw MoshWireError.truncated
        }
        var cursor = 0
        let dirSeq = try datagram.readBigEndian(UInt64.self, cursor: &cursor)
        let body = Data(datagram[cursor...])
        let ciphertext = Data(body.dropLast(16))
        let tag = Data(body.suffix(16))
        let nonce = OCBNonce.from(messageID: 0, sequence: dirSeq)
        let plaintext = try cipher.open(ciphertext: ciphertext, nonce: nonce, tag: tag)
        return (dirSeq, plaintext)
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
    private let cipher: (any TransportCipher)?
    private let outgoingDirection: MoshDirection
    private let mtu: Int

    private var fragmenter: MoshFragmenter
    private var assembly: MoshFragmentAssembly
    private var snapshot: TransportRuntimeSnapshot
    private let debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"

    public init(endpoint: any DatagramEndpoint, outgoingDirection: MoshDirection, mtu: Int = 1200, cipher: (any TransportCipher)? = nil) {
        self.endpoint = endpoint
        self.outgoingDirection = outgoingDirection
        self.mtu = mtu
        self.cipher = cipher
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

    public func sendPayload(_ payload: Data) async throws {
        let sequence = snapshot.nextOutgoingSequence
        snapshot.nextOutgoingSequence &+= 1
        try await sendPayload(payload, sequence: sequence)
    }

    public func sendPayload(_ payload: Data, sequence: UInt64) async throws {
        let messageID = snapshot.nextInstructionID
        snapshot.nextInstructionID &+= 1

        let fragments = try fragmenter.makeFragments(messageID: messageID, encodedInstruction: payload, mtu: mtu - MoshWire.packetHeaderBytes)
        let timestamp = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        var currentSequence = sequence

        for index in fragments.indices {
            let fragment = fragments[index]
            let dirSeq = MoshWire.directionalSequence(sequence: currentSequence, direction: outgoingDirection)

            if let cipher {
                var plaintext = Data()
                plaintext.appendBigEndian(timestamp)
                plaintext.appendBigEndian(UInt16.max)
                plaintext.append(fragment.encoded())
                let sealed = try cipher.seal(directionalSequence: dirSeq, plaintext: plaintext)
                try await endpoint.send(sealed)
            } else {
                let packet = MoshPacket(
                    sequence: currentSequence,
                    direction: outgoingDirection,
                    timestamp: timestamp,
                    timestampReply: UInt16.max,
                    payload: fragment.encoded()
                )
                try await endpoint.send(MoshPacketCodec.encode(packet))
            }

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

            let packet: MoshPacket
            if let cipher {
                let (dirSeq, plaintext) = try cipher.open(datagram: datagram.data)
                let (seq, dir) = MoshWire.splitDirectionalSequence(dirSeq)
                guard plaintext.count >= 4 else { throw TransportError.malformedDatagram }
                let ts = (UInt16(plaintext[0]) << 8) | UInt16(plaintext[1])
                let tsr = (UInt16(plaintext[2]) << 8) | UInt16(plaintext[3])
                packet = MoshPacket(sequence: seq, direction: dir, timestamp: ts, timestampReply: tsr, payload: Data(plaintext.dropFirst(4)))
            } else {
                packet = try MoshPacketCodec.decode(datagram.data)
            }

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

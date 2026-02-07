import Foundation
import MoshCryptoOCB
import MoshTransport
import MoshWire

actor MoshEncryptedDatagramEndpoint: DatagramEndpoint {
    private let wrapped: any DatagramEndpoint
    private let cipher: OCBCipher
    private let debugEnabled: Bool

    init(wrapping wrapped: any DatagramEndpoint, key: Data) throws {
        self.wrapped = wrapped
        self.cipher = try OCBCipher(key: key)
        self.debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"
    }

    func start() async throws {
        try await wrapped.start()
    }

    func stop() async {
        await wrapped.stop()
    }

    func send(_ data: Data) async throws {
        let packet = try MoshPacketCodec.decode(data)
        let directionalSequence = MoshWire.directionalSequence(sequence: packet.sequence, direction: packet.direction)
        let nonce = OCBNonce.from(messageID: 0, sequence: directionalSequence)

        var plaintext = Data()
        plaintext.appendUInt16BE(packet.timestamp)
        plaintext.appendUInt16BE(packet.timestampReply)
        plaintext.append(packet.payload)

        let sealed = try cipher.seal(plaintext: plaintext, nonce: nonce)

        var encryptedDatagram = Data()
        encryptedDatagram.appendUInt64BE(directionalSequence)
        encryptedDatagram.append(sealed.ciphertext)
        encryptedDatagram.append(sealed.tag)
        if debugEnabled {
            debugLog("send seq=\(packet.sequence) dir=\(packet.direction) plain=\(plaintext.count) datagram=\(encryptedDatagram.count)")
        }
        try await wrapped.send(encryptedDatagram)
    }

    func receive() async throws -> TransportDatagram {
        let datagram = try await wrapped.receive()
        if debugEnabled {
            debugLog("recv datagram=\(datagram.data.count)")
        }
        let decoded: Data
        do {
            decoded = try decodeDatagram(datagram.data)
        } catch {
            if debugEnabled {
                debugLog("recv decode error: \(error)")
            }
            throw error
        }
        return TransportDatagram(data: decoded, receivedAtMs: datagram.receivedAtMs)
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshEncryptedDatagramEndpoint] \(message)\n".utf8))
    }

    private func decodeDatagram(_ data: Data) throws -> Data {
        var cursor = 0
        let directionalSequence = try data.readUInt64BE(cursor: &cursor)
        let encryptedBody = Data(data[cursor...])

        guard encryptedBody.count >= 16 else {
            throw MoshWireError.truncated
        }

        let ciphertext = Data(encryptedBody.dropLast(16))
        let tag = Data(encryptedBody.suffix(16))
        let nonce = OCBNonce.from(messageID: 0, sequence: directionalSequence)
        let plaintext = try cipher.open(ciphertext: ciphertext, nonce: nonce, tag: tag)

        guard plaintext.count >= 4 else {
            throw MoshWireError.truncated
        }

        let timestamp = (UInt16(plaintext[0]) << 8) | UInt16(plaintext[1])
        let timestampReply = (UInt16(plaintext[2]) << 8) | UInt16(plaintext[3])
        let payload = Data(plaintext.dropFirst(4))
        let (sequence, direction) = MoshWire.splitDirectionalSequence(directionalSequence)
        if debugEnabled {
            debugLog("decoded seq=\(sequence) dir=\(direction) ts=\(timestamp) tsr=\(timestampReply) payload=\(payload.count)")
        }
        let packet = MoshPacket(
            sequence: sequence,
            direction: direction,
            timestamp: timestamp,
            timestampReply: timestampReply,
            payload: payload
        )
        return MoshPacketCodec.encode(packet)
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func readUInt64BE(cursor: inout Int) throws -> UInt64 {
        let size = MemoryLayout<UInt64>.size
        guard cursor + size <= count else {
            throw MoshWireError.truncated
        }
        var value: UInt64 = 0
        for index in 0..<size {
            value = (value << 8) | UInt64(self[cursor + index])
        }
        cursor += size
        return value
    }
}

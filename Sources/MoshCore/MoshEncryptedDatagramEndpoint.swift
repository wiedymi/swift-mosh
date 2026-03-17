import Foundation
import MoshCryptoOCB
import MoshTransport
import MoshWire

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
        plaintext.appendBigEndian(packet.timestamp)
        plaintext.appendBigEndian(packet.timestampReply)
        plaintext.append(packet.payload)

        let sealed = try cipher.seal(plaintext: plaintext, nonce: nonce)

        var encryptedDatagram = Data()
        encryptedDatagram.appendBigEndian(directionalSequence)
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
        guard data.count >= 8 + 16 else {
            throw MoshWireError.truncated
        }
        var cursor = 0
        let directionalSequence = try data.readBigEndian(UInt64.self, cursor: &cursor)
        let body = Data(data[cursor...])
        let ciphertext = Data(body.dropLast(16))
        let tag = Data(body.suffix(16))
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

import Foundation

public enum OCBCipherError: Error, Sendable {
    case invalidNonceLength(Int)
    case invalidTagLength(Int)
    case authenticationFailed
    case invalidPrintableKeyLength(Int)
    case invalidPrintableKeyEncoding
}

public struct OCBSealedBox: Sendable, Hashable {
    public let ciphertext: Data
    public let tag: Data

    public init(ciphertext: Data, tag: Data) {
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public enum OCBNonce {
    public static let recommendedLength = 12

    public static func random(length: Int = recommendedLength) throws -> Data {
        guard (1...15).contains(length) else {
            throw OCBCipherError.invalidNonceLength(length)
        }

        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: length)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes)
    }

    public static func from(messageID: UInt32, sequence: UInt64) -> Data {
        var out = Data(capacity: MemoryLayout<UInt32>.size + MemoryLayout<UInt64>.size)

        var messageID = messageID.bigEndian
        Swift.withUnsafeBytes(of: &messageID) { out.append(contentsOf: $0) }

        var sequence = sequence.bigEndian
        Swift.withUnsafeBytes(of: &sequence) { out.append(contentsOf: $0) }

        return out
    }

    public static func validate(_ nonce: Data) throws {
        guard (1...15).contains(nonce.count) else {
            throw OCBCipherError.invalidNonceLength(nonce.count)
        }
    }
}

public struct MoshBase64Key: Sendable, Hashable, Codable {
    public let raw: Data

    public init(raw: Data) throws {
        guard raw.count == 16 else {
            throw OCBCipherError.invalidPrintableKeyLength(raw.count)
        }
        self.raw = raw
    }

    public init(printableKey: String) throws {
        guard printableKey.count == 22 else {
            throw OCBCipherError.invalidPrintableKeyLength(printableKey.count)
        }
        guard let decoded = Data(base64Encoded: printableKey + "=="), decoded.count == 16 else {
            throw OCBCipherError.invalidPrintableKeyEncoding
        }
        self.raw = decoded
    }

    public var printable: String {
        let encoded = raw.base64EncodedString()
        return String(encoded.prefix(22))
    }
}

public struct OCBCipher: Sendable {
    private let aes: AES128
    private let tagLength: Int

    public init(key: Data, tagLength: Int = 16) throws {
        guard (1...16).contains(tagLength) else {
            throw OCBCipherError.invalidTagLength(tagLength)
        }
        self.aes = try AES128(key: key)
        self.tagLength = tagLength
    }

    public func seal(
        plaintext: Data,
        nonce: Data,
        associatedData: Data = Data()
    ) throws -> OCBSealedBox {
        try OCBNonce.validate(nonce)

        let lStar = try aes.encryptBlockBytes(OCBBlockOps.zero)
        let lDollar = OCBBlockOps.double(lStar)
        var lValues = [OCBBlockOps.double(lDollar)] // L_0, L_1, ...

        let offset0 = try initialOffset(nonce: Array(nonce))
        let adHash = try hashAssociatedData(
            Array(associatedData),
            lStar: lStar,
            lValues: &lValues
        )

        let plaintextBytes = Array(plaintext)
        var offset = offset0
        var checksum = OCBBlockOps.zero
        var ciphertext = [UInt8]()
        ciphertext.reserveCapacity(plaintextBytes.count)

        let fullBlocks = plaintextBytes.count / 16
        if fullBlocks > 0 {
            for blockNumber in 1...fullBlocks {
                let blockStart = (blockNumber - 1) * 16
                let plainBlock = Array(plaintextBytes[blockStart..<blockStart + 16])
                offset = OCBBlockOps.xor(
                    offset,
                    lValue(forNTZ: blockNumber.trailingZeroBitCount, lValues: &lValues)
                )

                let encrypted = try aes.encryptBlockBytes(OCBBlockOps.xor(plainBlock, offset))
                let cipherBlock = OCBBlockOps.xor(encrypted, offset)

                ciphertext.append(contentsOf: cipherBlock)
                checksum = OCBBlockOps.xor(checksum, plainBlock)
            }
        }

        let remainder = plaintextBytes.count % 16
        if remainder > 0 {
            offset = OCBBlockOps.xor(offset, lStar)
            let pad = try aes.encryptBlockBytes(offset)

            let partialStart = fullBlocks * 16
            let partialPlaintext = Array(plaintextBytes[partialStart..<partialStart + remainder])
            ciphertext.append(contentsOf: OCBBlockOps.xorPrefix(partialPlaintext, with: pad))
            checksum = OCBBlockOps.xor(checksum, OCBBlockOps.pad(partialPlaintext))
        }

        let tagInput = OCBBlockOps.xor(OCBBlockOps.xor(checksum, offset), lDollar)
        let encryptedTagInput = try aes.encryptBlockBytes(tagInput)
        let fullTag = OCBBlockOps.xor(encryptedTagInput, adHash)

        return OCBSealedBox(
            ciphertext: Data(ciphertext),
            tag: Data(fullTag.prefix(tagLength))
        )
    }

    public func open(
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        associatedData: Data = Data()
    ) throws -> Data {
        try OCBNonce.validate(nonce)
        guard tag.count == tagLength else {
            throw OCBCipherError.invalidTagLength(tag.count)
        }

        let lStar = try aes.encryptBlockBytes(OCBBlockOps.zero)
        let lDollar = OCBBlockOps.double(lStar)
        var lValues = [OCBBlockOps.double(lDollar)] // L_0, L_1, ...

        let offset0 = try initialOffset(nonce: Array(nonce))
        let adHash = try hashAssociatedData(
            Array(associatedData),
            lStar: lStar,
            lValues: &lValues
        )

        let ciphertextBytes = Array(ciphertext)
        var offset = offset0
        var checksum = OCBBlockOps.zero
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(ciphertextBytes.count)

        let fullBlocks = ciphertextBytes.count / 16
        if fullBlocks > 0 {
            for blockNumber in 1...fullBlocks {
                let blockStart = (blockNumber - 1) * 16
                let cipherBlock = Array(ciphertextBytes[blockStart..<blockStart + 16])
                offset = OCBBlockOps.xor(
                    offset,
                    lValue(forNTZ: blockNumber.trailingZeroBitCount, lValues: &lValues)
                )

                let decrypted = try aes.decryptBlockBytes(OCBBlockOps.xor(cipherBlock, offset))
                let plainBlock = OCBBlockOps.xor(decrypted, offset)

                plaintext.append(contentsOf: plainBlock)
                checksum = OCBBlockOps.xor(checksum, plainBlock)
            }
        }

        let remainder = ciphertextBytes.count % 16
        if remainder > 0 {
            offset = OCBBlockOps.xor(offset, lStar)
            let pad = try aes.encryptBlockBytes(offset)

            let partialStart = fullBlocks * 16
            let partialCiphertext = Array(ciphertextBytes[partialStart..<partialStart + remainder])
            let partialPlaintext = OCBBlockOps.xorPrefix(partialCiphertext, with: pad)

            plaintext.append(contentsOf: partialPlaintext)
            checksum = OCBBlockOps.xor(checksum, OCBBlockOps.pad(partialPlaintext))
        }

        let tagInput = OCBBlockOps.xor(OCBBlockOps.xor(checksum, offset), lDollar)
        let encryptedTagInput = try aes.encryptBlockBytes(tagInput)
        let fullTag = OCBBlockOps.xor(encryptedTagInput, adHash)

        guard OCBBlockOps.constantTimeEqual(Array(tag), Array(fullTag.prefix(tag.count))) else {
            throw OCBCipherError.authenticationFailed
        }

        return Data(plaintext)
    }

    private func initialOffset(nonce: [UInt8]) throws -> [UInt8] {
        var nonceBlock = OCBBlockOps.zero
        nonceBlock[0] = UInt8(((tagLength * 8) % 128) << 1)

        let start = 16 - nonce.count
        nonceBlock[start - 1] |= 0x01
        for index in 0..<nonce.count {
            nonceBlock[start + index] = nonce[index]
        }

        let bottom = Int(nonceBlock[15] & 0x3F)
        nonceBlock[15] &= 0xC0

        let kTop = try aes.encryptBlockBytes(nonceBlock)
        var stretch = kTop
        for index in 0..<8 {
            stretch.append(kTop[index] ^ kTop[index + 1])
        }

        let byteShift = bottom / 8
        let bitShift = bottom % 8

        var offset = OCBBlockOps.zero
        for index in 0..<16 {
            let first = stretch[byteShift + index]
            if bitShift == 0 {
                offset[index] = first
            } else {
                let second = stretch[byteShift + index + 1]
                offset[index] = (first << bitShift) | (second >> (8 - bitShift))
            }
        }

        return offset
    }

    private func hashAssociatedData(
        _ associatedData: [UInt8],
        lStar: [UInt8],
        lValues: inout [[UInt8]]
    ) throws -> [UInt8] {
        var sum = OCBBlockOps.zero
        var offset = OCBBlockOps.zero

        let fullBlocks = associatedData.count / 16
        if fullBlocks > 0 {
            for blockNumber in 1...fullBlocks {
                let blockStart = (blockNumber - 1) * 16
                let block = Array(associatedData[blockStart..<blockStart + 16])
                offset = OCBBlockOps.xor(
                    offset,
                    lValue(forNTZ: blockNumber.trailingZeroBitCount, lValues: &lValues)
                )

                let encrypted = try aes.encryptBlockBytes(OCBBlockOps.xor(block, offset))
                sum = OCBBlockOps.xor(sum, encrypted)
            }
        }

        let remainder = associatedData.count % 16
        if remainder > 0 {
            let partialStart = fullBlocks * 16
            let partialBlock = Array(associatedData[partialStart..<partialStart + remainder])

            offset = OCBBlockOps.xor(offset, lStar)
            let encrypted = try aes.encryptBlockBytes(
                OCBBlockOps.xor(OCBBlockOps.pad(partialBlock), offset)
            )
            sum = OCBBlockOps.xor(sum, encrypted)
        }

        return sum
    }

    private func lValue(forNTZ ntz: Int, lValues: inout [[UInt8]]) -> [UInt8] {
        while lValues.count <= ntz {
            lValues.append(OCBBlockOps.double(lValues[lValues.count - 1]))
        }
        return lValues[ntz]
    }
}

private enum OCBBlockOps {
    static let zero = [UInt8](repeating: 0, count: 16)

    static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var output = zero
        for index in 0..<16 {
            output[index] = lhs[index] ^ rhs[index]
        }
        return output
    }

    static func xorPrefix(_ lhs: [UInt8], with rhs: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: lhs.count)
        for index in lhs.indices {
            output[index] = lhs[index] ^ rhs[index]
        }
        return output
    }

    static func double(_ block: [UInt8]) -> [UInt8] {
        var output = zero
        var carry: UInt8 = 0

        for index in stride(from: 15, through: 0, by: -1) {
            let value = block[index]
            output[index] = (value << 1) | carry
            carry = (value & 0x80) >> 7
        }

        if carry != 0 {
            output[15] ^= 0x87
        }

        return output
    }

    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        var output = zero
        for index in bytes.indices {
            output[index] = bytes[index]
        }
        if bytes.count < 16 {
            output[bytes.count] = 0x80
        }
        return output
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }
}

enum OCBTestHooks {
    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        OCBBlockOps.constantTimeEqual(lhs, rhs)
    }
}

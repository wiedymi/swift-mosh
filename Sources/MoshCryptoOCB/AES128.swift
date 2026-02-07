import Foundation

public enum AES128Error: Error, Sendable {
    case invalidKeyLength(Int)
    case invalidBlockLength(Int)
}

public struct AES128: Sendable {
    private static let rounds = 10
    private static let expandedKeyBytes = 176

    private static let sBox: [UInt8] = {
        var table = Array(repeating: UInt8(0), count: 256)
        for value in 0...255 {
            let inv = multiplicativeInverse(UInt8(value))
            table[value] = affineTransform(inv)
        }
        return table
    }()

    private static let inverseSBox: [UInt8] = {
        var table = Array(repeating: UInt8(0), count: 256)
        for value in 0...255 {
            table[Int(sBox[value])] = UInt8(value)
        }
        return table
    }()

    private static let rcon: [UInt8] = [
        0x00,
        0x01, 0x02, 0x04, 0x08, 0x10,
        0x20, 0x40, 0x80, 0x1B, 0x36
    ]

    private let expandedKey: [UInt8]

    public init(key: Data) throws {
        guard key.count == 16 else { throw AES128Error.invalidKeyLength(key.count) }
        self.expandedKey = AES128.expandKey(Array(key))
    }

    public func encryptBlock(_ block: Data) throws -> Data {
        try Data(encryptBlockBytes(Array(block)))
    }

    public func decryptBlock(_ block: Data) throws -> Data {
        try Data(decryptBlockBytes(Array(block)))
    }

    func encryptBlockBytes(_ block: [UInt8]) throws -> [UInt8] {
        guard block.count == 16 else { throw AES128Error.invalidBlockLength(block.count) }

        var state = block
        addRoundKey(&state, round: 0)

        for round in 1..<AES128.rounds {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, round: round)
        }

        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, round: AES128.rounds)

        return state
    }

    func decryptBlockBytes(_ block: [UInt8]) throws -> [UInt8] {
        guard block.count == 16 else { throw AES128Error.invalidBlockLength(block.count) }

        var state = block
        addRoundKey(&state, round: AES128.rounds)

        for round in stride(from: AES128.rounds - 1, through: 1, by: -1) {
            inverseShiftRows(&state)
            inverseSubBytes(&state)
            addRoundKey(&state, round: round)
            inverseMixColumns(&state)
        }

        inverseShiftRows(&state)
        inverseSubBytes(&state)
        addRoundKey(&state, round: 0)

        return state
    }

    private func addRoundKey(_ state: inout [UInt8], round: Int) {
        let offset = round * 16
        for i in 0..<16 {
            state[i] ^= expandedKey[offset + i]
        }
    }

    private func subBytes(_ state: inout [UInt8]) {
        for i in 0..<16 {
            state[i] = AES128.sBox[Int(state[i])]
        }
    }

    private func inverseSubBytes(_ state: inout [UInt8]) {
        for i in 0..<16 {
            state[i] = AES128.inverseSBox[Int(state[i])]
        }
    }

    private func shiftRows(_ state: inout [UInt8]) {
        let copy = state
        state[1] = copy[5]
        state[5] = copy[9]
        state[9] = copy[13]
        state[13] = copy[1]

        state[2] = copy[10]
        state[6] = copy[14]
        state[10] = copy[2]
        state[14] = copy[6]

        state[3] = copy[15]
        state[7] = copy[3]
        state[11] = copy[7]
        state[15] = copy[11]
    }

    private func inverseShiftRows(_ state: inout [UInt8]) {
        let copy = state
        state[1] = copy[13]
        state[5] = copy[1]
        state[9] = copy[5]
        state[13] = copy[9]

        state[2] = copy[10]
        state[6] = copy[14]
        state[10] = copy[2]
        state[14] = copy[6]

        state[3] = copy[7]
        state[7] = copy[11]
        state[11] = copy[15]
        state[15] = copy[3]
    }

    private func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let index = column * 4
            let s0 = state[index]
            let s1 = state[index + 1]
            let s2 = state[index + 2]
            let s3 = state[index + 3]

            state[index] = gmul(0x02, s0) ^ gmul(0x03, s1) ^ s2 ^ s3
            state[index + 1] = s0 ^ gmul(0x02, s1) ^ gmul(0x03, s2) ^ s3
            state[index + 2] = s0 ^ s1 ^ gmul(0x02, s2) ^ gmul(0x03, s3)
            state[index + 3] = gmul(0x03, s0) ^ s1 ^ s2 ^ gmul(0x02, s3)
        }
    }

    private func inverseMixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let index = column * 4
            let s0 = state[index]
            let s1 = state[index + 1]
            let s2 = state[index + 2]
            let s3 = state[index + 3]

            state[index] = gmul(0x0E, s0) ^ gmul(0x0B, s1) ^ gmul(0x0D, s2) ^ gmul(0x09, s3)
            state[index + 1] = gmul(0x09, s0) ^ gmul(0x0E, s1) ^ gmul(0x0B, s2) ^ gmul(0x0D, s3)
            state[index + 2] = gmul(0x0D, s0) ^ gmul(0x09, s1) ^ gmul(0x0E, s2) ^ gmul(0x0B, s3)
            state[index + 3] = gmul(0x0B, s0) ^ gmul(0x0D, s1) ^ gmul(0x09, s2) ^ gmul(0x0E, s3)
        }
    }

    private static func expandKey(_ key: [UInt8]) -> [UInt8] {
        var expanded = key
        expanded.reserveCapacity(expandedKeyBytes)

        var wordIndex = 4
        while expanded.count < expandedKeyBytes {
            var temp = Array(expanded.suffix(4))
            if wordIndex % 4 == 0 {
                temp = subWord(rotWord(temp))
                temp[0] ^= rcon[wordIndex / 4]
            }

            let prevWordStart = expanded.count - 16
            for i in 0..<4 {
                expanded.append(expanded[prevWordStart + i] ^ temp[i])
            }
            wordIndex += 1
        }

        return expanded
    }

    private static func rotWord(_ word: [UInt8]) -> [UInt8] {
        [word[1], word[2], word[3], word[0]]
    }

    private static func subWord(_ word: [UInt8]) -> [UInt8] {
        word.map { sBox[Int($0)] }
    }

    private static func multiplicativeInverse(_ value: UInt8) -> UInt8 {
        guard value != 0 else { return 0 }
        var result: UInt8 = 1
        var base = value
        var exponent: UInt16 = 254

        while exponent > 0 {
            if exponent & 1 == 1 {
                result = gmul(result, base)
            }
            base = gmul(base, base)
            exponent >>= 1
        }

        return result
    }

    private static func affineTransform(_ value: UInt8) -> UInt8 {
        value
            ^ rotateLeft(value, by: 1)
            ^ rotateLeft(value, by: 2)
            ^ rotateLeft(value, by: 3)
            ^ rotateLeft(value, by: 4)
            ^ 0x63
    }

    private static func rotateLeft(_ value: UInt8, by amount: UInt8) -> UInt8 {
        (value << amount) | (value >> (8 - amount))
    }

    private static func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a
        var b = b
        var product: UInt8 = 0

        for _ in 0..<8 {
            if b & 1 == 1 {
                product ^= a
            }
            let highBit = a & 0x80
            a <<= 1
            if highBit != 0 {
                a ^= 0x1B
            }
            b >>= 1
        }

        return product
    }

    private func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        AES128.gmul(a, b)
    }
}

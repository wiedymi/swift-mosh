import CommonCrypto
import Foundation

public enum AES128Error: Error, Sendable {
    case invalidKeyLength(Int)
    case invalidBlockLength(Int)
}

public struct AES128: Sendable {
    private let key: Data

    public init(key: Data) throws {
        guard key.count == 16 else { throw AES128Error.invalidKeyLength(key.count) }
        self.key = key
    }

    public func encryptBlock(_ block: Data) throws -> Data {
        try Data(encryptBlockBytes(Array(block)))
    }

    public func decryptBlock(_ block: Data) throws -> Data {
        try Data(decryptBlockBytes(Array(block)))
    }

    func encryptBlockBytes(_ block: [UInt8]) throws -> [UInt8] {
        guard block.count == 16 else { throw AES128Error.invalidBlockLength(block.count) }
        return try ccCrypt(operation: CCOperation(kCCEncrypt), input: block)
    }

    func decryptBlockBytes(_ block: [UInt8]) throws -> [UInt8] {
        guard block.count == 16 else { throw AES128Error.invalidBlockLength(block.count) }
        return try ccCrypt(operation: CCOperation(kCCDecrypt), input: block)
    }

    private func ccCrypt(operation: CCOperation, input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 16)
        var outputLength: Int = 0
        let status = key.withUnsafeBytes { keyPtr in
            input.withUnsafeBytes { inputPtr in
                output.withUnsafeMutableBytes { outputPtr in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        nil,
                        inputPtr.baseAddress, 16,
                        outputPtr.baseAddress, 16,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            fatalError("CCCrypt failed with status \(status)")
        }
        return output
    }
}

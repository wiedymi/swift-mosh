import Foundation
import XCTest
@testable import MoshCryptoOCB

final class AES128Tests: XCTestCase {
    func testAES128KnownVectorEncryptDecryptAndInternalBlockAPIs() throws {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let plaintext = Data(hex: "00112233445566778899AABBCCDDEEFF")
        let expectedCiphertext = Data(hex: "69C4E0D86A7B0430D8CDB78070B4C55A")

        let aes = try AES128(key: key)
        XCTAssertEqual(try aes.encryptBlock(plaintext), expectedCiphertext)
        XCTAssertEqual(try aes.decryptBlock(expectedCiphertext), plaintext)

        XCTAssertEqual(try Data(aes.encryptBlockBytes(Array(plaintext))), expectedCiphertext)
        XCTAssertEqual(try Data(aes.decryptBlockBytes(Array(expectedCiphertext))), plaintext)
    }

    func testAES128InvalidLengths() throws {
        XCTAssertThrowsError(try AES128(key: Data(repeating: 0, count: 15))) { error in
            guard case .invalidKeyLength(15) = error as? AES128Error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let aes = try AES128(key: Data(repeating: 1, count: 16))
        XCTAssertThrowsError(try aes.encryptBlock(Data(repeating: 0, count: 15))) { error in
            guard case .invalidBlockLength(15) = error as? AES128Error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try aes.decryptBlock(Data(repeating: 0, count: 15))) { error in
            guard case .invalidBlockLength(15) = error as? AES128Error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private extension Data {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        precondition(cleaned.count % 2 == 0)
        self.init()
        self.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byte = cleaned[index..<next]
            self.append(UInt8(byte, radix: 16)!)
            index = next
        }
    }
}

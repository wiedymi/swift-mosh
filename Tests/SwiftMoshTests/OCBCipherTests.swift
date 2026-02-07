import Foundation
import XCTest
@testable import MoshCryptoOCB

final class OCBCipherTests: XCTestCase {
    func testNonceAndPrintableKeyUtilities() throws {
        XCTAssertEqual(try OCBNonce.random().count, OCBNonce.recommendedLength)
        XCTAssertEqual(try OCBNonce.random(length: 1).count, 1)
        XCTAssertEqual(try OCBNonce.random(length: 15).count, 15)

        XCTAssertThrowsError(try OCBNonce.random(length: 0)) { error in
            guard case .invalidNonceLength(0) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try OCBNonce.random(length: 16)) { error in
            guard case .invalidNonceLength(16) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let nonce = OCBNonce.from(messageID: 0x11223344, sequence: 0x5566778899AABBCC)
        XCTAssertEqual(nonce, Data(hex: "112233445566778899AABBCC"))
        try OCBNonce.validate(nonce)
        XCTAssertThrowsError(try OCBNonce.validate(Data())) { error in
            guard case .invalidNonceLength(0) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let raw = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let keyFromRaw = try MoshBase64Key(raw: raw)
        let printable = keyFromRaw.printable
        XCTAssertEqual(printable.count, 22)
        XCTAssertEqual(try MoshBase64Key(printableKey: printable).raw, raw)

        XCTAssertThrowsError(try MoshBase64Key(raw: Data(repeating: 0, count: 15))) { error in
            guard case .invalidPrintableKeyLength(15) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try MoshBase64Key(printableKey: "too-short")) { error in
            guard case .invalidPrintableKeyLength(9) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try MoshBase64Key(printableKey: String(repeating: "!", count: 22))) { error in
            XCTAssertTrue(error is OCBCipherError)
        }
    }

    func testSealAndOpenRoundTripsAcrossBlockAndAssociatedDataShapes() throws {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let cipher = try OCBCipher(key: key)

        // empty plaintext + empty AD
        let nonceBitShiftZero = Data(hex: "0102030405060708090A0B00")
        let emptyBox = try cipher.seal(plaintext: Data(), nonce: nonceBitShiftZero, associatedData: Data())
        XCTAssertEqual(try cipher.open(ciphertext: emptyBox.ciphertext, nonce: nonceBitShiftZero, tag: emptyBox.tag, associatedData: Data()), Data())

        // exact block sizes
        let oneBlockPlaintext = Data((0..<16).map(UInt8.init))
        let oneBlockAD = Data((100..<116).map(UInt8.init))
        let exactBox = try cipher.seal(plaintext: oneBlockPlaintext, nonce: nonceBitShiftZero, associatedData: oneBlockAD)
        XCTAssertEqual(
            try cipher.open(ciphertext: exactBox.ciphertext, nonce: nonceBitShiftZero, tag: exactBox.tag, associatedData: oneBlockAD),
            oneBlockPlaintext
        )

        // full + partial blocks, with bottom bits forcing bitShift != 0 in initialOffset.
        let nonceBitShiftNonZero = Data(hex: "A102030405060708090A0B01")
        let mixedPlaintext = Data((0..<37).map { UInt8(($0 * 7) & 0xFF) })
        let mixedAD = Data((0..<19).map { UInt8(($0 * 11) & 0xFF) })
        let mixedBox = try cipher.seal(plaintext: mixedPlaintext, nonce: nonceBitShiftNonZero, associatedData: mixedAD)
        XCTAssertEqual(
            try cipher.open(ciphertext: mixedBox.ciphertext, nonce: nonceBitShiftNonZero, tag: mixedBox.tag, associatedData: mixedAD),
            mixedPlaintext
        )
    }

    func testOCBCipherErrorPaths() throws {
        XCTAssertThrowsError(try OCBCipher(key: Data(repeating: 0, count: 16), tagLength: 0)) { error in
            guard case .invalidTagLength(0) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try OCBCipher(key: Data(repeating: 0, count: 16), tagLength: 17)) { error in
            guard case .invalidTagLength(17) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try OCBCipher(key: Data(repeating: 0, count: 15))) { error in
            XCTAssertTrue(error is AES128Error)
        }

        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let cipher12 = try OCBCipher(key: key, tagLength: 12)
        let nonce = Data(hex: "0102030405060708090A0B0C")
        let box = try cipher12.seal(plaintext: Data([1, 2, 3]), nonce: nonce, associatedData: Data([9]))

        XCTAssertThrowsError(
            try cipher12.open(
                ciphertext: box.ciphertext,
                nonce: nonce,
                tag: box.tag.dropLast(),
                associatedData: Data([9])
            )
        ) { error in
            guard case .invalidTagLength(11) = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var tamperedTag = box.tag
        tamperedTag[tamperedTag.startIndex] ^= 0x01
        XCTAssertThrowsError(
            try cipher12.open(
                ciphertext: box.ciphertext,
                nonce: nonce,
                tag: tamperedTag,
                associatedData: Data([9])
            )
        ) { error in
            guard case .authenticationFailed = error as? OCBCipherError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testConstantTimeEqualLengthMismatchBranch() {
        XCTAssertFalse(OCBTestHooks.constantTimeEqual([0x01, 0x02], [0x01]))
        XCTAssertTrue(OCBTestHooks.constantTimeEqual([0xAA, 0xBB], [0xAA, 0xBB]))
    }

    func testRFC7253VectorEmptyPlaintextAndAD() throws {
        let key = Data(hex: "000102030405060708090A0B0C0D0E0F")
        let nonce = Data(hex: "000102030405060708090A0B")
        let expectedTag = Data(hex: "197B9C3C441D3C83EAFB2BEF633B9182")

        let cipher = try OCBCipher(key: key)
        let sealed = try cipher.seal(plaintext: Data(), nonce: nonce, associatedData: Data())
        XCTAssertEqual(sealed.ciphertext, Data())
        XCTAssertEqual(sealed.tag, expectedTag)
    }
}

private extension Data {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        precondition(cleaned.count.isMultiple(of: 2))
        self.init()
        self.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byte = cleaned[index..<next]
            append(UInt8(byte, radix: 16)!)
            index = next
        }
    }
}

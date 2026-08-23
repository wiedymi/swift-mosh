import Foundation
import XCTest
@testable import MoshProtoLite

final class ProtoLiteTests: XCTestCase {
    func testTransportInstructionRoundTripAndUnknownSkipping() throws {
        let original = TransportInstruction(
            protocolVersion: 2,
            oldNum: 10,
            newNum: 11,
            ackNum: 9,
            throwawayNum: 4,
            diff: Data([0xAA, 0xBB]),
            chaff: Data([0xCC])
        )
        let decoded = try TransportInstruction(decoding: original.encoded())
        XCTAssertEqual(decoded, original)

        let empty = try TransportInstruction(decoding: Data())
        XCTAssertEqual(empty, TransportInstruction())

        // Unknown fields should be skipped across all supported wire types.
        var bytes: [UInt8] = []
        bytes += varintField(number: 90, value: 1)
        bytes += fixed64Field(number: 91, bytes: Array(repeating: 0x44, count: 8))
        bytes += lengthDelimitedField(number: 92, payload: [0x01, 0x02, 0x03])
        bytes += fixed32Field(number: 93, bytes: [0x0A, 0x0B, 0x0C, 0x0D])
        bytes += varintField(number: 2, value: 777)
        let skipDecoded = try TransportInstruction(decoding: Data(bytes))
        XCTAssertEqual(skipDecoded.oldNum, 777)
    }

    func testTransportInstructionDecodeErrors() {
        XCTAssertThrowsError(try TransportInstruction(decoding: Data([0x00]))) { error in
            guard case .invalidFieldNumber(0) = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try TransportInstruction(decoding: Data([0x0B]))) { error in
            guard case .unsupportedWireType(3) = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try TransportInstruction(decoding: Data([0x08]))) { error in
            guard case .truncated = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try TransportInstruction(decoding: Data(Array(repeating: 0x80, count: 10)))) { error in
            guard case .malformedVarint = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let invalidLength = Data(tag(field: 6, wire: 2) + varint(UInt64.max))
        XCTAssertThrowsError(try TransportInstruction(decoding: invalidLength)) { error in
            guard case .invalidLength(UInt64.max) = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHostMessageRoundTripAndByteLevelDecodingBranches() throws {
        let message = HostMessage(
            instructions: [
                .hostBytes(Data([0x41, 0x42])),
                .resize(width: -80, height: 24),
                .echoAck(999),
                .quit
            ]
        )
        let decoded = try HostMessage(decoding: message.encoded())
        XCTAssertEqual(decoded, message)

        let hostBytesPayload = lengthDelimitedField(number: 4, payload: [0xDE, 0xAD])
            + varintField(number: 90, value: 7) // decodeHostBytes default -> skip
        let innerHostBytes = lengthDelimitedField(number: 2, payload: hostBytesPayload)
            + fixed32Field(number: 20, bytes: [1, 2, 3, 4]) // decodeHostInstruction default -> skip
        let resizePayload = varintField(number: 5, value: UInt64(bitPattern: Int64(-1)))
            + varintField(number: 6, value: 200)
            + fixed64Field(number: 21, bytes: Array(repeating: 0x55, count: 8)) // decodeResize default -> skip
        let innerResize = lengthDelimitedField(number: 3, payload: resizePayload)
        let echoPayload = varintField(number: 8, value: 1234)
            + fixed32Field(number: 22, bytes: [9, 9, 9, 9]) // decodeEchoAck default -> skip
        let innerEcho = lengthDelimitedField(number: 7, payload: echoPayload)
        let innerQuit = lengthDelimitedField(number: 9, payload: [])

        var top: [UInt8] = []
        top += varintField(number: 30, value: 10) // HostMessage default -> skip varint
        top += fixed64Field(number: 31, bytes: Array(repeating: 0xAA, count: 8)) // skip fixed64
        top += lengthDelimitedField(number: 32, payload: [0x01, 0x02]) // skip length-delimited
        top += fixed32Field(number: 33, bytes: [0x10, 0x20, 0x30, 0x40]) // skip fixed32
        top += lengthDelimitedField(number: 1, payload: innerHostBytes)
        top += lengthDelimitedField(number: 1, payload: innerResize)
        top += lengthDelimitedField(number: 1, payload: innerEcho)
        top += lengthDelimitedField(number: 1, payload: innerQuit)

        let parsed = try HostMessage(decoding: Data(top))
        XCTAssertEqual(parsed.instructions.count, 4)

        if case .hostBytes(let bytes) = parsed.instructions[0] {
            XCTAssertEqual(bytes, Data([0xDE, 0xAD]))
        } else {
            XCTFail("Expected hostBytes")
        }

        if case .resize(let width, let height) = parsed.instructions[1] {
            XCTAssertEqual(width, -1)
            XCTAssertEqual(height, 200)
        } else {
            XCTFail("Expected resize")
        }

        if case .echoAck(let value) = parsed.instructions[2] {
            XCTAssertEqual(value, 1234)
        } else {
            XCTFail("Expected echoAck")
        }

        guard case .quit = parsed.instructions[3] else {
            return XCTFail("Expected quit")
        }
    }

    func testHostMessageErrorPaths() {
        let missingInstructionPayload = Data(lengthDelimitedField(number: 1, payload: []))
        XCTAssertThrowsError(try HostMessage(decoding: missingInstructionPayload)) { error in
            guard case .missingRequiredField("HostInstruction") = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let truncatedLengthDelimited = Data([0x0A, 0x02, 0x01])
        XCTAssertThrowsError(try HostMessage(decoding: truncatedLengthDelimited)) { error in
            guard case .truncated = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let invalidLengthInSkip = Data(tag(field: 99, wire: 2) + varint(UInt64.max))
        XCTAssertThrowsError(try HostMessage(decoding: invalidLengthInSkip)) { error in
            guard case .invalidLength(UInt64.max) = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUserMessageRoundTripAndBranches() throws {
        let message = UserMessage(
            instructions: [
                .keystroke(Data([0x1B, 0x5B, 0x41])),
                .resize(width: 120, height: 50)
            ]
        )
        XCTAssertEqual(try UserMessage(decoding: message.encoded()), message)

        let keystrokePayload = lengthDelimitedField(number: 4, payload: [0x41])
            + fixed32Field(number: 91, bytes: [0x01, 0x02, 0x03, 0x04]) // decodeKeystroke default -> skip
        let innerKey = lengthDelimitedField(number: 2, payload: keystrokePayload)
            + varintField(number: 40, value: 1) // decodeUserInstruction default -> skip
        let userResizePayload = varintField(number: 5, value: UInt64(bitPattern: Int64(-32)))
            + varintField(number: 6, value: UInt64(bitPattern: Int64(-24)))
            + fixed64Field(number: 41, bytes: Array(repeating: 0xEE, count: 8)) // decodeUserResize default -> skip
        let innerResize = lengthDelimitedField(number: 3, payload: userResizePayload)

        var top: [UInt8] = []
        top += varintField(number: 50, value: 1) // top-level skip varint
        top += fixed64Field(number: 51, bytes: Array(repeating: 0x33, count: 8)) // skip fixed64
        top += fixed32Field(number: 52, bytes: [1, 2, 3, 4]) // skip fixed32
        top += lengthDelimitedField(number: 1, payload: innerKey)
        top += lengthDelimitedField(number: 1, payload: innerResize)

        let parsed = try UserMessage(decoding: Data(top))
        XCTAssertEqual(parsed.instructions.count, 2)

        if case .keystroke(let bytes) = parsed.instructions[0] {
            XCTAssertEqual(bytes, Data([0x41]))
        } else {
            XCTFail("Expected keystroke")
        }

        if case .resize(let width, let height) = parsed.instructions[1] {
            XCTAssertEqual(width, -32)
            XCTAssertEqual(height, -24)
        } else {
            XCTFail("Expected resize")
        }
    }

    func testUserMessageMissingRequiredField() {
        let missingInstructionPayload = Data(lengthDelimitedField(number: 1, payload: []))
        XCTAssertThrowsError(try UserMessage(decoding: missingInstructionPayload)) { error in
            guard case .missingRequiredField("UserInstruction") = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testProtoLiteSkipBytesDefensiveBranches() {
        XCTAssertThrowsError(try ProtoLiteTestHooks.skipBytes(count: -1, inDataOfLength: 4)) { error in
            guard case .invalidLength(UInt64(bitPattern: -1)) = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try ProtoLiteTestHooks.skipBytes(count: 4, inDataOfLength: 2, initialOffset: 1)) { error in
            guard case .truncated = error as? ProtoLiteError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertNoThrow(try ProtoLiteTestHooks.skipBytes(count: 1, inDataOfLength: 2))
    }
}

private func tag(field: UInt64, wire: UInt64) -> [UInt8] {
    varint((field << 3) | wire)
}

private func varintField(number: UInt64, value: UInt64) -> [UInt8] {
    tag(field: number, wire: 0) + varint(value)
}

private func lengthDelimitedField(number: UInt64, payload: [UInt8]) -> [UInt8] {
    tag(field: number, wire: 2) + varint(UInt64(payload.count)) + payload
}

private func fixed64Field(number: UInt64, bytes: [UInt8]) -> [UInt8] {
    precondition(bytes.count == 8)
    return tag(field: number, wire: 1) + bytes
}

private func fixed32Field(number: UInt64, bytes: [UInt8]) -> [UInt8] {
    precondition(bytes.count == 4)
    return tag(field: number, wire: 5) + bytes
}

private func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var output: [UInt8] = []
    while true {
        if value < 0x80 {
            output.append(UInt8(value))
            return output
        }
        output.append(UInt8(value & 0x7F) | 0x80)
        value >>= 7
    }
}

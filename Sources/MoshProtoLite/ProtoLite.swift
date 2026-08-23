import Foundation
import OSLog

private let protoLiteLogger = Logger(
    subsystem: "com.mymosh.app",
    category: "MoshProtoLite"
)

#if DEBUG
private let protoLiteDebugEnabled = true
#else
private let protoLiteDebugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"
#endif

public enum ProtoLiteError: Error, Sendable {
    case truncated
    case malformedVarint
    case unsupportedWireType(UInt64)
    case invalidFieldNumber(UInt64)
    case invalidLength(UInt64)
    case missingRequiredField(String)
}

public struct TransportInstruction: Sendable, Hashable, Codable {
    public var protocolVersion: UInt32?
    public var oldNum: UInt64?
    public var newNum: UInt64?
    public var ackNum: UInt64?
    public var throwawayNum: UInt64?
    public var diff: Data?
    public var chaff: Data?

    public init(
        protocolVersion: UInt32? = nil,
        oldNum: UInt64? = nil,
        newNum: UInt64? = nil,
        ackNum: UInt64? = nil,
        throwawayNum: UInt64? = nil,
        diff: Data? = nil,
        chaff: Data? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.oldNum = oldNum
        self.newNum = newNum
        self.ackNum = ackNum
        self.throwawayNum = throwawayNum
        self.diff = diff
        self.chaff = chaff
    }

    public func encoded() -> Data {
        var data = Data()
        if let protocolVersion {
            ProtoWriter.writeVarintField(number: 1, value: UInt64(protocolVersion), to: &data)
        }
        if let oldNum {
            ProtoWriter.writeVarintField(number: 2, value: oldNum, to: &data)
        }
        if let newNum {
            ProtoWriter.writeVarintField(number: 3, value: newNum, to: &data)
        }
        if let ackNum {
            ProtoWriter.writeVarintField(number: 4, value: ackNum, to: &data)
        }
        if let throwawayNum {
            ProtoWriter.writeVarintField(number: 5, value: throwawayNum, to: &data)
        }
        if let diff {
            ProtoWriter.writeBytesField(number: 6, value: diff, to: &data)
        }
        if let chaff {
            ProtoWriter.writeBytesField(number: 7, value: chaff, to: &data)
        }
        return data
    }

    public init(decoding data: Data) throws {
        var reader = ProtoReader(data: data)
        var protocolVersion: UInt32?
        var oldNum: UInt64?
        var newNum: UInt64?
        var ackNum: UInt64?
        var throwawayNum: UInt64?
        var diff: Data?
        var chaff: Data?

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (1, .varint):
                let value = try reader.readVarint()
                protocolVersion = UInt32(truncatingIfNeeded: value)
            case (2, .varint):
                oldNum = try reader.readVarint()
            case (3, .varint):
                newNum = try reader.readVarint()
            case (4, .varint):
                ackNum = try reader.readVarint()
            case (5, .varint):
                throwawayNum = try reader.readVarint()
            case (6, .lengthDelimited):
                diff = try reader.readLengthDelimited()
            case (7, .lengthDelimited):
                chaff = try reader.readLengthDelimited()
            default:
                try reader.skip(wireType: wire)
            }
        }

        self.protocolVersion = protocolVersion
        self.oldNum = oldNum
        self.newNum = newNum
        self.ackNum = ackNum
        self.throwawayNum = throwawayNum
        self.diff = diff
        self.chaff = chaff
    }
}

public enum HostInstruction: Sendable, Hashable, Codable {
    case hostBytes(Data)
    case resize(width: Int32, height: Int32)
    case echoAck(UInt64)
    case quit
}

public struct HostMessage: Sendable, Hashable, Codable {
    public var instructions: [HostInstruction]

    public init(instructions: [HostInstruction] = []) {
        self.instructions = instructions
    }

    public func encoded() -> Data {
        var data = Data()
        for instruction in instructions {
            ProtoWriter.writeBytesField(number: 1, value: Self.encodeHostInstruction(instruction), to: &data)
        }
        return data
    }

    public init(decoding data: Data) throws {
        var reader = ProtoReader(data: data)
        var instructions: [HostInstruction] = []

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (1, .lengthDelimited):
                let payload = try reader.readLengthDelimited()
                instructions.append(try Self.decodeHostInstruction(payload))
            default:
                logSkippedProtoField("HostMessage", field: field, wire: wire)
                try reader.skip(wireType: wire)
            }
        }

        self.instructions = instructions
    }

    private static func encodeHostInstruction(_ instruction: HostInstruction) -> Data {
        var data = Data()
        switch instruction {
        case .hostBytes(let bytes):
            var hostBytes = Data()
            ProtoWriter.writeBytesField(number: 4, value: bytes, to: &hostBytes)
            ProtoWriter.writeBytesField(number: 2, value: hostBytes, to: &data)
        case .resize(let width, let height):
            var resize = Data()
            ProtoWriter.writeVarintField(number: 5, value: UInt64(bitPattern: Int64(width)), to: &resize)
            ProtoWriter.writeVarintField(number: 6, value: UInt64(bitPattern: Int64(height)), to: &resize)
            ProtoWriter.writeBytesField(number: 3, value: resize, to: &data)
        case .echoAck(let value):
            var echo = Data()
            ProtoWriter.writeVarintField(number: 8, value: value, to: &echo)
            ProtoWriter.writeBytesField(number: 7, value: echo, to: &data)
        case .quit:
            ProtoWriter.writeBytesField(number: 9, value: Data(), to: &data)
        }
        return data
    }

    private static func decodeHostInstruction(_ data: Data) throws -> HostInstruction {
        var reader = ProtoReader(data: data)
        var result: HostInstruction?

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (2, .lengthDelimited):
                result = try decodeHostBytes(try reader.readLengthDelimited())
            case (3, .lengthDelimited):
                let resize = try reader.readLengthDelimited()
                result = try decodeResize(resize)
            case (7, .lengthDelimited):
                let echoPayload = try reader.readLengthDelimited()
                result = try decodeEchoAck(echoPayload)
            case (9, .lengthDelimited):
                _ = try reader.readLengthDelimited()
                result = .quit
            default:
                logSkippedProtoField("HostInstruction", field: field, wire: wire)
                try reader.skip(wireType: wire)
            }
        }

        guard let result else {
            throw ProtoLiteError.missingRequiredField("HostInstruction")
        }
        return result
    }

    private static func decodeHostBytes(_ data: Data) throws -> HostInstruction {
        var reader = ProtoReader(data: data)
        var bytes = Data()

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (4, .lengthDelimited):
                bytes = try reader.readLengthDelimited()
            default:
                try reader.skip(wireType: wire)
            }
        }

        return .hostBytes(bytes)
    }

    private static func decodeResize(_ data: Data) throws -> HostInstruction {
        var reader = ProtoReader(data: data)
        var width: Int32 = 0
        var height: Int32 = 0

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (5, .varint):
                width = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            case (6, .varint):
                height = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            default:
                try reader.skip(wireType: wire)
            }
        }

        return .resize(width: width, height: height)
    }

    private static func decodeEchoAck(_ data: Data) throws -> HostInstruction {
        var reader = ProtoReader(data: data)
        var ack: UInt64 = 0

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (8, .varint):
                ack = try reader.readVarint()
            default:
                try reader.skip(wireType: wire)
            }
        }

        return .echoAck(ack)
    }
}

public enum UserInstruction: Sendable, Hashable, Codable {
    case keystroke(Data)
    case resize(width: Int32, height: Int32)
}

public struct UserMessage: Sendable, Hashable, Codable {
    public var instructions: [UserInstruction]

    public init(instructions: [UserInstruction] = []) {
        self.instructions = instructions
    }

    public func encoded() -> Data {
        var data = Data()
        for instruction in instructions {
            ProtoWriter.writeBytesField(number: 1, value: Self.encodeUserInstruction(instruction), to: &data)
        }
        return data
    }

    public init(decoding data: Data) throws {
        var reader = ProtoReader(data: data)
        var instructions: [UserInstruction] = []

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (1, .lengthDelimited):
                instructions.append(try Self.decodeUserInstruction(try reader.readLengthDelimited()))
            default:
                try reader.skip(wireType: wire)
            }
        }

        self.instructions = instructions
    }

    private static func encodeUserInstruction(_ instruction: UserInstruction) -> Data {
        var data = Data()
        switch instruction {
        case .keystroke(let bytes):
            var keystroke = Data()
            ProtoWriter.writeBytesField(number: 4, value: bytes, to: &keystroke)
            ProtoWriter.writeBytesField(number: 2, value: keystroke, to: &data)
        case .resize(let width, let height):
            var resize = Data()
            ProtoWriter.writeVarintField(number: 5, value: UInt64(bitPattern: Int64(width)), to: &resize)
            ProtoWriter.writeVarintField(number: 6, value: UInt64(bitPattern: Int64(height)), to: &resize)
            ProtoWriter.writeBytesField(number: 3, value: resize, to: &data)
        }
        return data
    }

    private static func decodeUserInstruction(_ data: Data) throws -> UserInstruction {
        var reader = ProtoReader(data: data)
        var result: UserInstruction?

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (2, .lengthDelimited):
                result = try decodeKeystroke(try reader.readLengthDelimited())
            case (3, .lengthDelimited):
                result = try decodeUserResize(try reader.readLengthDelimited())
            default:
                try reader.skip(wireType: wire)
            }
        }

        guard let result else {
            throw ProtoLiteError.missingRequiredField("UserInstruction")
        }
        return result
    }

    private static func decodeKeystroke(_ data: Data) throws -> UserInstruction {
        var reader = ProtoReader(data: data)
        var bytes = Data()

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (4, .lengthDelimited):
                bytes = try reader.readLengthDelimited()
            default:
                try reader.skip(wireType: wire)
            }
        }

        return .keystroke(bytes)
    }

    private static func decodeUserResize(_ data: Data) throws -> UserInstruction {
        var reader = ProtoReader(data: data)
        var width: Int32 = 0
        var height: Int32 = 0

        while !reader.isAtEnd {
            let (field, wire) = try reader.readFieldHeader()
            switch (field, wire) {
            case (5, .varint):
                width = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            case (6, .varint):
                height = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            default:
                try reader.skip(wireType: wire)
            }
        }

        return .resize(width: width, height: height)
    }
}

private enum ProtoWireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

private func logSkippedProtoField(
    _ message: String,
    field: UInt64,
    wire: ProtoWireType
) {
    guard protoLiteDebugEnabled else { return }
    protoLiteLogger.notice(
        "\(message, privacy: .public) skipped field=\(field, privacy: .public) wire=\(wire.rawValue, privacy: .public)"
    )
}

private enum ProtoWriter {
    static func writeTag(fieldNumber: UInt64, wireType: ProtoWireType, to output: inout Data) {
        writeVarint((fieldNumber << 3) | wireType.rawValue, to: &output)
    }

    static func writeVarintField(number: UInt64, value: UInt64, to output: inout Data) {
        writeTag(fieldNumber: number, wireType: .varint, to: &output)
        writeVarint(value, to: &output)
    }

    static func writeBytesField(number: UInt64, value: Data, to output: inout Data) {
        writeTag(fieldNumber: number, wireType: .lengthDelimited, to: &output)
        writeVarint(UInt64(value.count), to: &output)
        output.append(value)
    }

    static func writeVarint(_ value: UInt64, to output: inout Data) {
        var value = value
        while value >= 0x80 {
            output.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
    }
}

private struct ProtoReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(data: Data) {
        self.bytes = Array(data)
        self.offset = 0
    }

    var isAtEnd: Bool {
        offset >= bytes.count
    }

    mutating func readFieldHeader() throws -> (field: UInt64, wire: ProtoWireType) {
        let key = try readVarint()
        let field = key >> 3
        guard field > 0 else {
            throw ProtoLiteError.invalidFieldNumber(field)
        }

        let wireRaw = key & 0x07
        guard let wire = ProtoWireType(rawValue: wireRaw) else {
            throw ProtoLiteError.unsupportedWireType(wireRaw)
        }

        return (field, wire)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while shift < 64 {
            guard offset < bytes.count else {
                throw ProtoLiteError.truncated
            }

            let byte = bytes[offset]
            offset += 1

            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }

        throw ProtoLiteError.malformedVarint
    }

    mutating func readLengthDelimited() throws -> Data {
        let rawLength = try readVarint()
        guard let length = Int(exactly: rawLength) else {
            throw ProtoLiteError.invalidLength(rawLength)
        }
        guard offset + length <= bytes.count else {
            throw ProtoLiteError.truncated
        }

        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }

    mutating func skip(wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            try skipBytes(8)
        case .lengthDelimited:
            let rawLength = try readVarint()
            guard let length = Int(exactly: rawLength) else {
                throw ProtoLiteError.invalidLength(rawLength)
            }
            try skipBytes(length)
        case .fixed32:
            try skipBytes(4)
        }
    }

    private mutating func skipBytes(_ count: Int) throws {
        guard count >= 0 else {
            throw ProtoLiteError.invalidLength(UInt64(bitPattern: Int64(count)))
        }
        guard offset + count <= bytes.count else {
            throw ProtoLiteError.truncated
        }
        offset += count
    }
}

enum ProtoLiteTestHooks {
    static func skipBytes(
        count: Int,
        inDataOfLength length: Int,
        initialOffset: Int = 0
    ) throws {
        var reader = ProtoReader(data: Data(repeating: 0, count: max(0, length)))
        try reader.skipBytesForTesting(count: count, initialOffset: initialOffset)
    }
}

private extension ProtoReader {
    mutating func skipBytesForTesting(count: Int, initialOffset: Int) throws {
        self.offset = initialOffset
        try skipBytes(count)
    }
}

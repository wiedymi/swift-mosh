import Foundation

public enum MoshDirection: UInt8, Sendable, Codable {
    case toServer = 0
    case toClient = 1
}

public enum MoshWireError: Error, Sendable {
    case truncated
    case invalidDirection(UInt8)
    case invalidMTU(Int)
    case fragmentIncomplete
    case fragmentHeaderTooSmall
    case missingFragment(UInt16)
}

public enum MoshWire {
    public static let protocolVersion: UInt32 = 2
    public static let packetHeaderBytes = 8 + 2 + 2
    public static let fragmentHeaderBytes = 8 + 2

    public static func timestamp16(nowMilliseconds: UInt64) -> UInt16 {
        var value = UInt16(nowMilliseconds % 65_536)
        if value == UInt16.max {
            value &-= 1
        }
        return value
    }

    public static func timestampDiff(new: UInt16, old: UInt16) -> UInt16 {
        let diff = Int(new) - Int(old)
        if diff >= 0 {
            return UInt16(diff)
        }
        return UInt16(diff + 65_536)
    }

    public static func directionalSequence(sequence: UInt64, direction: MoshDirection) -> UInt64 {
        let dirBit = UInt64(direction.rawValue) << 63
        let seqMask = UInt64.max ^ (UInt64(1) << 63)
        return dirBit | (sequence & seqMask)
    }

    public static func splitDirectionalSequence(_ directionalSequence: UInt64) -> (sequence: UInt64, direction: MoshDirection) {
        let dir = ((directionalSequence >> 63) & 1) == 1 ? MoshDirection.toClient : .toServer
        let seqMask = UInt64.max ^ (UInt64(1) << 63)
        return (directionalSequence & seqMask, dir)
    }
}

public struct MoshPacket: Sendable, Hashable, Codable {
    public var sequence: UInt64
    public var direction: MoshDirection
    public var timestamp: UInt16
    public var timestampReply: UInt16
    public var payload: Data

    public init(
        sequence: UInt64,
        direction: MoshDirection,
        timestamp: UInt16,
        timestampReply: UInt16,
        payload: Data
    ) {
        self.sequence = sequence
        self.direction = direction
        self.timestamp = timestamp
        self.timestampReply = timestampReply
        self.payload = payload
    }
}

public enum MoshPacketCodec {
    public static func encode(_ packet: MoshPacket) -> Data {
        var data = Data()
        data.appendBigEndian(MoshWire.directionalSequence(sequence: packet.sequence, direction: packet.direction))
        data.appendBigEndian(packet.timestamp)
        data.appendBigEndian(packet.timestampReply)
        data.append(packet.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> MoshPacket {
        var cursor = 0
        let directionalSequence = try data.readBigEndian(UInt64.self, cursor: &cursor)
        let (sequence, direction) = MoshWire.splitDirectionalSequence(directionalSequence)
        let timestamp = try data.readBigEndian(UInt16.self, cursor: &cursor)
        let timestampReply = try data.readBigEndian(UInt16.self, cursor: &cursor)
        let payload = data.suffix(from: cursor)
        return MoshPacket(
            sequence: sequence,
            direction: direction,
            timestamp: timestamp,
            timestampReply: timestampReply,
            payload: Data(payload)
        )
    }
}

public struct MoshFragment: Sendable, Hashable, Codable {
    public var id: UInt64
    public var fragmentNumber: UInt16
    public var final: Bool
    public var contents: Data

    public init(id: UInt64, fragmentNumber: UInt16, final: Bool, contents: Data) {
        self.id = id
        self.fragmentNumber = fragmentNumber
        self.final = final
        self.contents = contents
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendBigEndian(id)
        let combined = (final ? UInt16(0x8000) : 0) | (fragmentNumber & 0x7FFF)
        data.appendBigEndian(combined)
        data.append(contents)
        return data
    }

    public init(decoding data: Data) throws {
        guard data.count >= MoshWire.fragmentHeaderBytes else {
            throw MoshWireError.fragmentHeaderTooSmall
        }
        var cursor = 0
        id = try data.readBigEndian(UInt64.self, cursor: &cursor)
        let combined = try data.readBigEndian(UInt16.self, cursor: &cursor)
        final = (combined & 0x8000) != 0
        fragmentNumber = combined & 0x7FFF
        contents = Data(data.suffix(from: cursor))
    }
}

public struct MoshFragmenter: Sendable {
    public init() {}

    public func makeFragments(messageID: UInt64, encodedInstruction: Data, mtu: Int) throws -> [MoshFragment] {
        guard mtu > MoshWire.fragmentHeaderBytes else {
            throw MoshWireError.invalidMTU(mtu)
        }

        let maxFragmentData = mtu - MoshWire.fragmentHeaderBytes
        if encodedInstruction.isEmpty {
            return [MoshFragment(id: messageID, fragmentNumber: 0, final: true, contents: Data())]
        }

        var fragments: [MoshFragment] = []
        var offset = 0
        var index: UInt16 = 0

        while offset < encodedInstruction.count {
            let end = min(offset + maxFragmentData, encodedInstruction.count)
            let chunk = Data(encodedInstruction[offset..<end])
            let isFinal = end == encodedInstruction.count
            fragments.append(MoshFragment(id: messageID, fragmentNumber: index, final: isFinal, contents: chunk))
            offset = end
            index &+= 1
        }

        return fragments
    }
}

public struct MoshFragmentAssembly: Sendable {
    private var currentID: UInt64?
    private var fragments: [UInt16: Data]
    private var totalFragments: UInt16?

    public init() {
        currentID = nil
        fragments = [:]
        totalFragments = nil
    }

    public mutating func reset() {
        currentID = nil
        fragments.removeAll(keepingCapacity: false)
        totalFragments = nil
    }

    public mutating func add(_ fragment: MoshFragment) -> Bool {
        if currentID != fragment.id {
            reset()
            currentID = fragment.id
        }

        fragments[fragment.fragmentNumber] = fragment.contents

        if fragment.final {
            totalFragments = fragment.fragmentNumber &+ 1
        }

        guard let totalFragments else {
            return false
        }
        return fragments.count == Int(totalFragments)
    }

    public mutating func assembled() throws -> Data {
        guard let totalFragments else {
            throw MoshWireError.fragmentIncomplete
        }

        var data = Data()
        for index in UInt16(0)..<totalFragments {
            guard let chunk = fragments[index] else {
                throw MoshWireError.missingFragment(index)
            }
            data.append(chunk)
        }
        reset()
        return data
    }
}

public extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { bytes in
            append(contentsOf: bytes)
        }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, cursor: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard cursor + size <= count else {
            throw MoshWireError.truncated
        }
        var value: T = 0
        for byte in self[cursor..<(cursor + size)] {
            value = (value << 8) | T(byte)
        }
        cursor += size
        return value
    }
}

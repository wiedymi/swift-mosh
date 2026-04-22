import Foundation
import XCTest
@testable import SwiftMosh

final class WirePrimitivesTests: XCTestCase {
    func testTimestampDirectionalSequenceAndPacketRoundTrip() throws {
        XCTAssertEqual(MoshWire.timestamp16(nowMilliseconds: 65_535), 65_534)
        XCTAssertEqual(MoshWire.timestamp16(nowMilliseconds: 65_536), 0)
        XCTAssertEqual(MoshWire.timestampDiff(new: 10, old: 2), 8)
        XCTAssertEqual(MoshWire.timestampDiff(new: 2, old: 10), 65_528)

        let directional = MoshWire.directionalSequence(sequence: UInt64.max, direction: .toClient)
        let split = MoshWire.splitDirectionalSequence(directional)
        XCTAssertEqual(split.sequence, UInt64.max ^ (UInt64(1) << 63))
        XCTAssertEqual(split.direction, .toClient)

        let packet = MoshPacket(
            sequence: 42,
            direction: .toServer,
            timestamp: 1_234,
            timestampReply: 4_321,
            payload: Data([0xAA, 0xBB, 0xCC])
        )
        let encoded = MoshPacketCodec.encode(packet)
        let decoded = try MoshPacketCodec.decode(encoded)
        XCTAssertEqual(decoded, packet)
    }

    func testPacketDecodeThrowsTruncated() {
        XCTAssertThrowsError(try MoshPacketCodec.decode(Data([0x01, 0x02, 0x03]))) { error in
            guard case .truncated = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFragmentEncodingFragmenterAndAssemblyBranches() throws {
        let fragment = MoshFragment(id: 9, fragmentNumber: 7, final: true, contents: Data([1, 2, 3]))
        let decoded = try MoshFragment(decoding: fragment.encoded())
        XCTAssertEqual(decoded, fragment)

        XCTAssertThrowsError(try MoshFragment(decoding: Data(repeating: 0, count: MoshWire.fragmentHeaderBytes - 1))) { error in
            guard case .fragmentHeaderTooSmall = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let fragmenter = MoshFragmenter()
        XCTAssertThrowsError(
            try fragmenter.makeFragments(messageID: 1, encodedInstruction: Data([1]), mtu: MoshWire.fragmentHeaderBytes)
        ) { error in
            guard case .invalidMTU(MoshWire.fragmentHeaderBytes) = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let empty = try fragmenter.makeFragments(messageID: 11, encodedInstruction: Data(), mtu: 64)
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty[0], MoshFragment(id: 11, fragmentNumber: 0, final: true, contents: Data()))

        let payload = Data(0..<20)
        let many = try fragmenter.makeFragments(messageID: 12, encodedInstruction: payload, mtu: MoshWire.fragmentHeaderBytes + 8)
        XCTAssertEqual(many.map(\.fragmentNumber), [0, 1, 2])
        XCTAssertEqual(many.map(\.final), [false, false, true])

        var assembly = MoshFragmentAssembly()
        XCTAssertThrowsError(try assembly.assembled()) { error in
            guard case .fragmentIncomplete = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertFalse(assembly.add(many[0]))
        XCTAssertFalse(assembly.add(many[1]))
        XCTAssertTrue(assembly.add(many[2]))
        XCTAssertEqual(try assembly.assembled(), payload)

        // New message ID should reset prior partial state.
        XCTAssertFalse(assembly.add(MoshFragment(id: 100, fragmentNumber: 0, final: false, contents: Data([0x01]))))
        XCTAssertFalse(assembly.add(MoshFragment(id: 101, fragmentNumber: 0, final: false, contents: Data([0x02]))))
        XCTAssertTrue(assembly.add(MoshFragment(id: 101, fragmentNumber: 1, final: true, contents: Data([0x03]))))
        XCTAssertEqual(try assembly.assembled(), Data([0x02, 0x03]))

        var missing = MoshFragmentAssembly()
        XCTAssertFalse(missing.add(MoshFragment(id: 500, fragmentNumber: 0, final: false, contents: Data([0x0A]))))
        XCTAssertFalse(missing.add(MoshFragment(id: 500, fragmentNumber: 2, final: true, contents: Data([0x0B]))))
        XCTAssertThrowsError(try missing.assembled()) { error in
            guard case .missingFragment(1) = error as? MoshWireError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

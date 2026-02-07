import Compression
import Foundation
import XCTest
import zlib
@testable import MoshCompression

final class CompressionAdapterTests: XCTestCase {
    func testCompressionRoundTripForAllAlgorithmsAndLargePayload() throws {
        let codec = MoshCompressionCodec()
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 & 0xFF) })

        for algorithm in [MoshCompressionAlgorithm.zlib, .lz4, .lzfse] {
            let compressed = try codec.compress(payload, algorithm: algorithm)
            XCTAssertFalse(compressed.isEmpty)
            let decompressed = try codec.decompress(compressed, algorithm: algorithm)
            XCTAssertEqual(decompressed, payload)
            XCTAssertEqual(try codec.uncompress(compressed, algorithm: algorithm), payload)
        }
    }

    func testCompressionEmptyInputAndErrorPaths() throws {
        let codec = MoshCompressionCodec()

        XCTAssertEqual(try codec.compress(Data(), algorithm: .zlib), Data())
        XCTAssertEqual(try codec.decompress(Data(), algorithm: .zlib), Data())

        let zlibCompressedEmpty = Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try codec.decompress(zlibCompressedEmpty, algorithm: .zlib)) { error in
            guard let typed = error as? MoshCompressionError else {
                return XCTFail("Unexpected error: \(error)")
            }
            switch typed {
            case .invalidCompressedData, .processFailed:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try codec.decompress(Data([0xFF, 0xFE, 0xFD, 0xFC]), algorithm: .zlib)) { error in
            XCTAssertTrue(error is MoshCompressionError)
        }
    }

    func testDeterministicCompressionErrorBranches() throws {
        let initFailCodec = MoshCompressionCodec(
            streamInit: { _, _, _ in COMPRESSION_STATUS_ERROR },
            streamProcess: { _, _ in COMPRESSION_STATUS_END },
            streamDestroy: { _ in }
        )
        XCTAssertThrowsError(
            try initFailCodec.processForTesting(
                Data([0x01]),
                operation: COMPRESSION_STREAM_ENCODE,
                algorithm: .zlib
            )
        ) { error in
            guard case .streamInitFailed = error as? MoshCompressionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let emptyDecodeCodec = MoshCompressionCodec(
            streamInit: { _, _, _ in COMPRESSION_STATUS_OK },
            streamProcess: { _, _ in COMPRESSION_STATUS_END },
            streamDestroy: { _ in }
        )
        XCTAssertThrowsError(try emptyDecodeCodec.decompress(Data([0xAB]), algorithm: .zlib)) { error in
            guard case .invalidCompressedData = error as? MoshCompressionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let fallbackSourceCodec = MoshCompressionCodec(
            streamInit: { _, _, _ in COMPRESSION_STATUS_OK },
            streamProcess: { _, _ in COMPRESSION_STATUS_END },
            streamDestroy: { _ in },
            forceSourcePointerFallback: true
        )
        XCTAssertEqual(
            try fallbackSourceCodec.processForTesting(
                Data([0x01]),
                operation: COMPRESSION_STREAM_ENCODE,
                algorithm: .zlib
            ),
            Data()
        )

        let processFailCodec = MoshCompressionCodec(
            streamInit: { _, _, _ in COMPRESSION_STATUS_OK },
            streamProcess: { _, _ in COMPRESSION_STATUS_ERROR },
            streamDestroy: { _ in }
        )
        XCTAssertThrowsError(
            try processFailCodec.processForTesting(
                Data([0x01]),
                operation: COMPRESSION_STREAM_ENCODE,
                algorithm: .lz4
            )
        ) { error in
            guard case .processFailed = error as? MoshCompressionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testZlibCompatibilityWithLibzAndInjectedErrorPaths() throws {
        let codec = MoshCompressionCodec()
        let libzCompressed = Data([
            0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
            0x2f, 0xca, 0x49, 0x01, 0x00, 0x1a, 0x0b, 0x04, 0x5d
        ])
        let decoded = try codec.decompress(libzCompressed, algorithm: .zlib)
        XCTAssertEqual(decoded, Data("hello world".utf8))

        let payload = Data("zlib interop".utf8)
        let swiftCompressed = try codec.compress(payload, algorithm: .zlib)
        var out = [UInt8](repeating: 0, count: 1024)
        var outLen: uLongf = uLongf(out.count)
        let rc = swiftCompressed.withUnsafeBytes { raw in
            uncompress(
                &out,
                &outLen,
                raw.bindMemory(to: Bytef.self).baseAddress,
                uLong(swiftCompressed.count)
            )
        }
        XCTAssertEqual(rc, Z_OK)
        XCTAssertEqual(Data(out.prefix(Int(outLen))), payload)

        let zlibCompressFail = MoshCompressionCodec(
            streamInit: { _, _, _ in COMPRESSION_STATUS_OK },
            streamProcess: { _, _ in COMPRESSION_STATUS_END },
            streamDestroy: { _ in },
            zlibCompress: { _, _, _, _, _ in Z_MEM_ERROR },
            zlibCompressBound: { length in compressBound(length) },
            zlibInflateInit: { stream, version, streamSize in inflateInit_(stream, version, streamSize) },
            zlibInflate: { stream, flags in inflate(stream, flags) },
            zlibInflateEnd: { stream in inflateEnd(stream) }
        )
        XCTAssertThrowsError(try zlibCompressFail.compress(Data([0x11]), algorithm: .zlib)) { error in
            guard case .zlibError(Z_MEM_ERROR) = error as? MoshCompressionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let zlibInflateInitFail = MoshCompressionCodec(
            streamInit: { _, _, _ in COMPRESSION_STATUS_OK },
            streamProcess: { _, _ in COMPRESSION_STATUS_END },
            streamDestroy: { _ in },
            zlibCompress: { dst, dstLen, src, srcLen, level in compress2(dst, dstLen, src, srcLen, level) },
            zlibCompressBound: { length in compressBound(length) },
            zlibInflateInit: { _, _, _ in Z_VERSION_ERROR },
            zlibInflate: { stream, flags in inflate(stream, flags) },
            zlibInflateEnd: { stream in inflateEnd(stream) }
        )
        XCTAssertThrowsError(try zlibInflateInitFail.decompress(libzCompressed, algorithm: .zlib)) { error in
            guard case .zlibError(Z_VERSION_ERROR) = error as? MoshCompressionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

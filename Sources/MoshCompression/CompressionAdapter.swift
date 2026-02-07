import Compression
import Foundation
import zlib

public enum MoshCompressionError: Error, Sendable {
    case streamInitFailed
    case processFailed
    case invalidCompressedData
    case zlibError(Int32)
}

public enum MoshCompressionAlgorithm: String, Sendable, Hashable, Codable {
    case zlib
    case lz4
    case lzfse

    var rawCompressionAlgorithm: compression_algorithm {
        switch self {
        case .zlib:
            return COMPRESSION_ZLIB
        case .lz4:
            return COMPRESSION_LZ4
        case .lzfse:
            return COMPRESSION_LZFSE
        }
    }
}

public struct MoshCompressionCodec: Sendable {
    internal typealias StreamInit = @Sendable (
        UnsafeMutablePointer<compression_stream>,
        compression_stream_operation,
        compression_algorithm
    ) -> compression_status
    internal typealias StreamProcess = @Sendable (
        UnsafeMutablePointer<compression_stream>,
        Int32
    ) -> compression_status
    internal typealias StreamDestroy = @Sendable (UnsafeMutablePointer<compression_stream>) -> Void
    internal typealias ZlibCompress = @Sendable (
        UnsafeMutablePointer<Bytef>?,
        UnsafeMutablePointer<uLongf>?,
        UnsafePointer<Bytef>?,
        uLong,
        Int32
    ) -> Int32
    internal typealias ZlibCompressBound = @Sendable (uLong) -> uLong
    internal typealias ZlibInflateInit = @Sendable (
        UnsafeMutablePointer<z_stream>?,
        UnsafePointer<CChar>?,
        Int32
    ) -> Int32
    internal typealias ZlibInflate = @Sendable (UnsafeMutablePointer<z_stream>?, Int32) -> Int32
    internal typealias ZlibInflateEnd = @Sendable (UnsafeMutablePointer<z_stream>?) -> Int32

    private static let chunkSize = 16 * 1024
    private let streamInit: StreamInit
    private let streamProcess: StreamProcess
    private let streamDestroy: StreamDestroy
    private let zlibCompressImpl: ZlibCompress
    private let zlibCompressBoundImpl: ZlibCompressBound
    private let zlibInflateInitImpl: ZlibInflateInit
    private let zlibInflateImpl: ZlibInflate
    private let zlibInflateEndImpl: ZlibInflateEnd
    private let forceSourcePointerFallback: Bool

    public init() {
        self.streamInit = { stream, operation, algorithm in
            compression_stream_init(stream, operation, algorithm)
        }
        self.streamProcess = { stream, flags in
            compression_stream_process(stream, flags)
        }
        self.streamDestroy = { stream in
            compression_stream_destroy(stream)
        }
        self.zlibCompressImpl = { dst, dstLen, src, srcLen, level in
            compress2(dst, dstLen, src, srcLen, level)
        }
        self.zlibCompressBoundImpl = { length in
            compressBound(length)
        }
        self.zlibInflateInitImpl = { stream, version, streamSize in
            inflateInit_(stream, version, streamSize)
        }
        self.zlibInflateImpl = { stream, flags in
            inflate(stream, flags)
        }
        self.zlibInflateEndImpl = { stream in
            inflateEnd(stream)
        }
        self.forceSourcePointerFallback = false
    }

    internal init(
        streamInit: @escaping StreamInit,
        streamProcess: @escaping StreamProcess,
        streamDestroy: @escaping StreamDestroy,
        forceSourcePointerFallback: Bool = false
    ) {
        self.init(
            streamInit: streamInit,
            streamProcess: streamProcess,
            streamDestroy: streamDestroy,
            forceSourcePointerFallback: forceSourcePointerFallback,
            zlibCompress: compress2,
            zlibCompressBound: compressBound,
            zlibInflateInit: { stream, version, streamSize in
                inflateInit_(stream, version, streamSize)
            },
            zlibInflate: { stream, flags in
                inflate(stream, flags)
            },
            zlibInflateEnd: { stream in
                inflateEnd(stream)
            }
        )
    }

    internal init(
        streamInit: @escaping StreamInit,
        streamProcess: @escaping StreamProcess,
        streamDestroy: @escaping StreamDestroy,
        forceSourcePointerFallback: Bool = false,
        zlibCompress: @escaping ZlibCompress,
        zlibCompressBound: @escaping ZlibCompressBound,
        zlibInflateInit: @escaping ZlibInflateInit,
        zlibInflate: @escaping ZlibInflate,
        zlibInflateEnd: @escaping ZlibInflateEnd
    ) {
        self.streamInit = streamInit
        self.streamProcess = streamProcess
        self.streamDestroy = streamDestroy
        self.zlibCompressImpl = zlibCompress
        self.zlibCompressBoundImpl = zlibCompressBound
        self.zlibInflateInitImpl = zlibInflateInit
        self.zlibInflateImpl = zlibInflate
        self.zlibInflateEndImpl = zlibInflateEnd
        self.forceSourcePointerFallback = forceSourcePointerFallback
    }

    public func compress(_ data: Data, algorithm: MoshCompressionAlgorithm = .zlib) throws -> Data {
        if data.isEmpty {
            return Data()
        }
        if algorithm == .zlib {
            return try zlibCompress(data)
        }
        return try process(data, operation: COMPRESSION_STREAM_ENCODE, algorithm: algorithm)
    }

    public func decompress(_ data: Data, algorithm: MoshCompressionAlgorithm = .zlib) throws -> Data {
        if data.isEmpty {
            return Data()
        }
        let result: Data
        if algorithm == .zlib {
            result = try zlibDecompress(data)
        } else {
            result = try process(data, operation: COMPRESSION_STREAM_DECODE, algorithm: algorithm)
        }
        if result.isEmpty {
            throw MoshCompressionError.invalidCompressedData
        }
        return result
    }

    public func uncompress(_ data: Data, algorithm: MoshCompressionAlgorithm = .zlib) throws -> Data {
        try decompress(data, algorithm: algorithm)
    }

    internal func processForTesting(
        _ data: Data,
        operation: compression_stream_operation,
        algorithm: MoshCompressionAlgorithm
    ) throws -> Data {
        try process(data, operation: operation, algorithm: algorithm)
    }

    private func process(
        _ data: Data,
        operation: compression_stream_operation,
        algorithm: MoshCompressionAlgorithm
    ) throws -> Data {
        let inScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let outScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            inScratch.deallocate()
            outScratch.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: outScratch,
            dst_size: 0,
            src_ptr: UnsafePointer(inScratch),
            src_size: 0,
            state: nil
        )

        let initStatus = streamInit(&stream, operation, algorithm.rawCompressionAlgorithm)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw MoshCompressionError.streamInitFailed
        }
        defer { streamDestroy(&stream) }

        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { outputBuffer.deallocate() }

        var output = Data()

        try data.withUnsafeBytes { source in
            let boundSource = source.bindMemory(to: UInt8.self)
            if !forceSourcePointerFallback, let baseAddress = boundSource.baseAddress {
                stream.src_ptr = baseAddress
            } else {
                stream.src_ptr = UnsafePointer(inScratch)
            }
            stream.src_size = source.count

            var shouldContinue = true
            while shouldContinue {
                stream.dst_ptr = outputBuffer
                stream.dst_size = Self.chunkSize

                let flags: Int32 = stream.src_size == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = streamProcess(&stream, flags)

                let written = Self.chunkSize - stream.dst_size
                if written > 0 {
                    output.append(outputBuffer, count: written)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    break
                case COMPRESSION_STATUS_END:
                    shouldContinue = false
                default:
                    throw MoshCompressionError.processFailed
                }
            }
        }

        return output
    }

    private func zlibCompress(_ data: Data) throws -> Data {
        var destinationSize = zlibCompressBoundImpl(uLong(data.count))
        var destination = Data(count: Int(destinationSize))

        let status = destination.withUnsafeMutableBytes { destRaw in
            data.withUnsafeBytes { srcRaw in
                let srcPtr = srcRaw.bindMemory(to: Bytef.self).baseAddress
                let destPtr = destRaw.bindMemory(to: Bytef.self).baseAddress
                return zlibCompressImpl(destPtr, &destinationSize, srcPtr, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }

        guard status == Z_OK else {
            throw MoshCompressionError.zlibError(status)
        }
        destination.removeSubrange(Int(destinationSize)..<destination.count)
        return destination
    }

    private func zlibDecompress(_ data: Data) throws -> Data {
        let chunkSize = 16 * 1024
        var output = Data()
        var stream = z_stream()

        let initStatus = zlibInflateInitImpl(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw MoshCompressionError.zlibError(initStatus)
        }
        defer {
            _ = zlibInflateEndImpl(&stream)
        }

        return try data.withUnsafeBytes { srcRaw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcRaw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            let bufferCount = buffer.count
            while true {
                let status = buffer.withUnsafeMutableBytes { outRaw -> Int32 in
                    stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bufferCount)
                    return zlibInflateImpl(&stream, Z_NO_FLUSH)
                }

                let produced = bufferCount - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    throw MoshCompressionError.invalidCompressedData
                }
                if stream.avail_in == 0, produced == 0 {
                    throw MoshCompressionError.invalidCompressedData
                }
            }

            return output
        }
    }
}

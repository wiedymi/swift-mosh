import Foundation
import NIOCore
import NIOPosix

// MARK: - Pipeline Types

struct MoshReassembledFrame {
    var timestamp: UInt16
    var timestampReply: UInt16
    var payload: ByteBuffer
}

struct MoshInboundEnvelope {
    var timestampReply: UInt16
    var instruction: TransportInstruction
}

// MARK: - OCB Cipher Handlers

final class OCBDecryptHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias InboundOut = ByteBuffer

    private let cipher: OCBCipher
    private let debugEnabled: Bool

    init(key: Data) throws {
        self.cipher = try OCBCipher(key: key)
        self.debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data

        guard buffer.readableBytes >= 8 + 16 else {
            if debugEnabled { debugLog("datagram too short: \(buffer.readableBytes)") }
            return
        }

        guard let dirSeq = buffer.readInteger(endianness: .big, as: UInt64.self) else {
            context.fireErrorCaught(MoshWireError.truncated)
            return
        }

        let body = buffer.readSlice(length: buffer.readableBytes)!
        guard let bodyData = body.getData(at: 0, length: body.readableBytes) else {
            context.fireErrorCaught(MoshWireError.truncated)
            return
        }

        let ciphertext = Data(bodyData.dropLast(16))
        let tag = Data(bodyData.suffix(16))
        let nonce = OCBNonce.from(messageID: 0, sequence: dirSeq)

        do {
            let plaintext = try cipher.open(ciphertext: ciphertext, nonce: nonce, tag: tag)
            guard plaintext.count >= 4 else {
                if debugEnabled { debugLog("plaintext too short: \(plaintext.count)") }
                return
            }

            var out = context.channel.allocator.buffer(capacity: 8 + plaintext.count)
            out.writeInteger(dirSeq, endianness: .big, as: UInt64.self)
            out.writeBytes(plaintext)
            context.fireChannelRead(wrapInboundOut(out))
        } catch {
            if debugEnabled { debugLog("decrypt failed: \(error)") }
            context.fireErrorCaught(error)
        }
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[OCBDecryptHandler] \(message)\n".utf8))
    }
}

final class OCBEncryptHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let cipher: OCBCipher
    private let remoteAddress: SocketAddress

    init(key: Data, remoteAddress: SocketAddress) throws {
        self.cipher = try OCBCipher(key: key)
        self.remoteAddress = remoteAddress
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        guard let dirSeq = buffer.readInteger(endianness: .big, as: UInt64.self) else {
            promise?.fail(MoshWireError.truncated)
            return
        }
        guard let payloadData = buffer.readData(length: buffer.readableBytes) else {
            promise?.fail(MoshWireError.truncated)
            return
        }

        let nonce = OCBNonce.from(messageID: 0, sequence: dirSeq)
        do {
            let sealed = try cipher.seal(plaintext: payloadData, nonce: nonce)
            var out = context.channel.allocator.buffer(capacity: 8 + sealed.ciphertext.count + sealed.tag.count)
            out.writeInteger(dirSeq, endianness: .big, as: UInt64.self)
            out.writeBytes(sealed.ciphertext)
            out.writeBytes(sealed.tag)
            let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: out)
            context.write(wrapOutboundOut(envelope), promise: promise)
        } catch {
            promise?.fail(error)
        }
    }
}

// MARK: - Mosh Packet Codec Handlers

final class MoshPacketDecoder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = MoshPacket

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let packetData = buffer.readData(length: buffer.readableBytes) else { return }
        do {
            let packet = try MoshPacketCodec.decode(packetData)
            context.fireChannelRead(wrapInboundOut(packet))
        } catch {
            context.fireErrorCaught(error)
        }
    }
}

final class MoshPacketEncoder: ChannelOutboundHandler {
    typealias OutboundIn = MoshPacket
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let packet = unwrapOutboundIn(data)
        let encoded = MoshPacketCodec.encode(packet)
        var buffer = context.channel.allocator.buffer(capacity: encoded.count)
        buffer.writeBytes(encoded)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
}

// MARK: - Mosh Fragment Handlers

final class MoshFrameDecoder: ChannelInboundHandler {
    typealias InboundIn = MoshPacket
    typealias InboundOut = MoshReassembledFrame

    private var assembly = MoshFragmentAssembly()
    private var currentMeta: (timestamp: UInt16, timestampReply: UInt16)?
    private let debugEnabled: Bool

    init() {
        self.debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        do {
            let fragment = try MoshFragment(decoding: packet.payload)
            if debugEnabled {
                debugLog("fragment id=\(fragment.id) num=\(fragment.fragmentNumber) final=\(fragment.final)")
            }

            currentMeta = (packet.timestamp, packet.timestampReply)
            let isComplete = assembly.add(fragment)
            guard isComplete else { return }

            let assembled = try assembly.assembled()
            var buffer = context.channel.allocator.buffer(capacity: assembled.count)
            buffer.writeBytes(assembled)

            let meta = currentMeta!
            currentMeta = nil

            let frame = MoshReassembledFrame(timestamp: meta.timestamp, timestampReply: meta.timestampReply, payload: buffer)
            if debugEnabled { debugLog("assembly complete: \(assembled.count) bytes") }
            context.fireChannelRead(wrapInboundOut(frame))
        } catch {
            context.fireErrorCaught(error)
        }
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshFrameDecoder] \(message)\n".utf8))
    }
}

final class MoshFrameEncoder: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = MoshPacket

    private var nextInstructionID: UInt64 = 0
    private let mtu: Int
    private let outgoingDirection: MoshDirection
    private var nextOutgoingSequence: UInt64 = 0
    private let debugEnabled: Bool

    init(mtu: Int, outgoingDirection: MoshDirection) {
        self.mtu = mtu
        self.outgoingDirection = outgoingDirection
        self.debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        guard let payload = buffer.readData(length: buffer.readableBytes) else {
            promise?.succeed(())
            return
        }

        let messageID = nextInstructionID
        nextInstructionID &+= 1

        do {
            let fragments = try MoshFragmenter().makeFragments(
                messageID: messageID,
                encodedInstruction: payload,
                mtu: mtu - MoshWire.packetHeaderBytes
            )
            let timestamp = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())

            guard !fragments.isEmpty else {
                promise?.succeed(())
                return
            }

            let subPromise = context.eventLoop.makePromise(of: Void.self)
            subPromise.futureResult.whenComplete { result in
                promise?.completeWith(result)
            }

            for (index, fragment) in fragments.enumerated() {
                let packet = MoshPacket(
                    sequence: nextOutgoingSequence,
                    direction: outgoingDirection,
                    timestamp: timestamp,
                    timestampReply: UInt16.max,
                    payload: fragment.encoded()
                )
                nextOutgoingSequence &+= 1

                let p = (index == fragments.count - 1) ? subPromise : nil
                context.write(wrapOutboundOut(packet), promise: p)
            }
            context.flush()

            if debugEnabled {
                debugLog("sent \(fragments.count) fragments, nextSeq=\(nextOutgoingSequence)")
            }
        } catch {
            promise?.fail(error)
        }
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshFrameEncoder] \(message)\n".utf8))
    }
}

// MARK: - Payload Codec Handlers

final class MoshPayloadDecoder: ChannelInboundHandler {
    typealias InboundIn = MoshReassembledFrame
    typealias InboundOut = MoshInboundEnvelope

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var payload = frame.payload
        guard let payloadData = payload.readData(length: payload.readableBytes) else { return }

        let codec = MoshCompressionCodec()
        let decompressed = try? codec.decompress(payloadData, algorithm: .zlib)
        let instructionBytes: Data
        let instruction: TransportInstruction

        if let decompressed,
           let candidate = try? TransportInstruction(decoding: decompressed),
           hasContent(candidate) {
            instructionBytes = decompressed
            instruction = candidate
        } else {
            instructionBytes = payloadData
            do {
                instruction = try TransportInstruction(decoding: instructionBytes)
            } catch {
                context.fireErrorCaught(error)
                return
            }
        }

        let envelope = MoshInboundEnvelope(timestampReply: frame.timestampReply, instruction: instruction)
        context.fireChannelRead(wrapInboundOut(envelope))
    }

    private func hasContent(_ instruction: TransportInstruction) -> Bool {
        instruction.protocolVersion != nil ||
        instruction.oldNum != nil ||
        instruction.newNum != nil ||
        instruction.ackNum != nil ||
        instruction.throwawayNum != nil ||
        instruction.diff != nil ||
        instruction.chaff != nil
    }
}

final class MoshPayloadEncoder: ChannelOutboundHandler {
    typealias OutboundIn = TransportInstruction
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let instruction = unwrapOutboundIn(data)
        let encoded = instruction.encoded()
        do {
            let compressed = try MoshCompressionCodec().compress(encoded, algorithm: .zlib)
            var buffer = context.channel.allocator.buffer(capacity: compressed.count)
            buffer.writeBytes(compressed)
            context.write(wrapOutboundOut(buffer), promise: promise)
        } catch {
            promise?.fail(error)
        }
    }
}

// MARK: - Delivery Handler

final class MoshDeliveryHandler: ChannelInboundHandler {
    typealias InboundIn = MoshInboundEnvelope

    private let onEnvelope: @Sendable (MoshInboundEnvelope) -> Void

    init(onEnvelope: @escaping @Sendable (MoshInboundEnvelope) -> Void) {
        self.onEnvelope = onEnvelope
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        onEnvelope(envelope)
    }
}

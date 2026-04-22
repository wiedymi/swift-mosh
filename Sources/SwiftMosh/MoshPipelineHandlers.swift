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

    private let mtu: Int
    private let outgoingDirection: MoshDirection
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

        guard let sessionContext = context.channel.moshContext else {
            promise?.fail(MoshSessionError.notStarted)
            return
        }

        let messageID = sessionContext.reserveInstructionID()

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
                    sequence: sessionContext.reserveOutgoingSequence(),
                    direction: outgoingDirection,
                    timestamp: timestamp,
                    timestampReply: UInt16.max,
                    payload: fragment.encoded()
                )

                let p = (index == fragments.count - 1) ? subPromise : nil
                context.write(wrapOutboundOut(packet), promise: p)
            }
            context.flush()

            if debugEnabled {
                let nextSeq = sessionContext.nextOutgoingSequence
                debugLog("sent \(fragments.count) fragments, nextSeq=\(nextSeq)")
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

// MARK: - Protocol Handler

final class MoshProtocolHandler: ChannelDuplexHandler {
    typealias InboundIn = MoshInboundEnvelope
    typealias InboundOut = [MoshHostOp]
    typealias OutboundIn = TransportInstruction
    typealias OutboundOut = TransportInstruction

    private let debugEnabled: Bool
    private var ackTimer: Scheduled<Void>?

    init() {
        self.debugEnabled = ProcessInfo.processInfo.environment["SWIFTMOSH_DEBUG_REAL_E2E"] == "1"
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        ackTimer?.cancel()
        ackTimer = nil
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let instruction = unwrapOutboundIn(data)

        guard let sessionContext = context.channel.moshContext else {
            promise?.fail(MoshSessionError.notStarted)
            return
        }

        if let newNum = instruction.newNum, newNum > sessionContext.lastSentStateNum {
            sessionContext.updateLastSentStateNum(newNum)
            let now = TransportClock.nowMs()
            let pending = PendingOutboundInstruction(
                stateNum: newNum,
                instruction: instruction,
                retryCount: 0,
                lastSentAtMs: now,
                nextRetryAtMs: now &+ UInt64(sessionContext.currentRtoClampedMs())
            )
            sessionContext.enqueuePendingOutbound(pending)
        }

        context.write(wrapOutboundOut(instruction), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)

        guard let sessionContext = context.channel.moshContext else {
            context.fireChannelRead(wrapInboundOut([MoshHostOp]()))
            return
        }

        do {
            let hostOps = try processInbound(envelope, context: context, sessionContext: sessionContext)
            context.fireChannelRead(wrapInboundOut(hostOps))
        } catch {
            context.fireErrorCaught(error)
        }
    }

    private func processInbound(_ envelope: MoshInboundEnvelope, context: ChannelHandlerContext, sessionContext: MoshSessionContext) throws -> [MoshHostOp] {
        let instruction = envelope.instruction

        sessionContext.recordReceived()
        updateRtt(timestampReply: envelope.timestampReply, sessionContext: sessionContext)

        if let version = instruction.protocolVersion, version != MoshWire.protocolVersion {
            throw SessionRuntimeError.fatal(.protocolViolation("mosh protocol mismatch: got \(version)"))
        }

        if let ack = instruction.ackNum {
            sessionContext.acknowledgePendingOutbound(through: ack)
        }
        if let throwaway = instruction.throwawayNum, throwaway > 0 {
            sessionContext.pruneAppliedRemoteStates(before: throwaway)
        }

        if let newNum = instruction.newNum {
            if sessionContext.isStateAlreadyApplied(newNum) {
                return []
            }
            if let oldNum = instruction.oldNum, sessionContext.isOldNumTooFarAhead(oldNum) {
                return []
            }
            sessionContext.applyRemoteStateNum(newNum)
            scheduleAck(context: context, sessionContext: sessionContext)
        }

        guard let diff = instruction.diff else {
            return []
        }

        if let hostMessage = try? HostMessage(decoding: diff), !hostMessage.instructions.isEmpty {
            return hostMessage.instructions.map { instr in
                switch instr {
                case .hostBytes(let bytes):
                    return .hostBytes(bytes)
                case .resize(let width, let height):
                    return .resize(cols: width, rows: height)
                case .echoAck(let value):
                    return .echoAck(value)
                }
            }
        }

        return [.hostBytes(diff)]
    }

    private func updateRtt(timestampReply: UInt16, sessionContext: MoshSessionContext) {
        guard timestampReply != UInt16.max else { return }
        let now16 = MoshWire.timestamp16(nowMilliseconds: TransportClock.nowMs())
        let sample = Double(MoshWire.timestampDiff(new: now16, old: timestampReply))
        sessionContext.applyRttSample(sample)
    }

    private func scheduleAck(context: ChannelHandlerContext, sessionContext: MoshSessionContext) {
        ackTimer?.cancel()
        let delayMs = Int64(sessionContext.config.ackDelayMs)
        ackTimer = context.eventLoop.scheduleTask(in: .milliseconds(delayMs)) { [self] in
            self.flushAck(context: context, sessionContext: sessionContext)
        }
    }

    private func flushAck(context: ChannelHandlerContext, sessionContext: MoshSessionContext) {
        let lastSent = sessionContext.lastSentStateNum
        let latestReceived = sessionContext.latestReceivedStateNum
        let instruction = TransportInstruction(
            protocolVersion: MoshWire.protocolVersion,
            oldNum: lastSent,
            newNum: lastSent,
            ackNum: latestReceived,
            throwawayNum: sessionContext.pendingOutboundStateNums().first ?? 0,
            diff: nil,
            chaff: Data()
        )
        context.write(wrapOutboundOut(instruction), promise: nil)
        context.flush()
        if debugEnabled {
            debugLog("auto-ack latestReceived=\(latestReceived)")
        }
    }

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("[MoshProtocolHandler] \(message)\n".utf8))
    }
}

// MARK: - Session Event

public enum MoshSessionEvent: Sendable {
    case hostOps([MoshHostOp])
    case error(Error)
}

// MARK: - Event Handler

final class MoshEventHandler: ChannelInboundHandler {
    typealias InboundIn = [MoshHostOp]

    private let onEvent: @Sendable (MoshSessionEvent) -> Void

    init(onEvent: @escaping @Sendable (MoshSessionEvent) -> Void) {
        self.onEvent = onEvent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let hostOps = unwrapInboundIn(data)
        onEvent(.hostOps(hostOps))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onEvent(.error(error))
        context.close(promise: nil)
    }
}

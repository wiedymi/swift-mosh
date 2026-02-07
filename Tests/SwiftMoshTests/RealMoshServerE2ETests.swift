import Darwin
import Foundation
import XCTest
@testable import MoshCore

final class RealMoshServerE2ETests: XCTestCase {
    func testRealMoshServerRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SWIFTMOSH_REAL_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTMOSH_REAL_E2E=1 to run real mosh-server integration tests.")
        }

        let host = env["SWIFTMOSH_REAL_E2E_HOST"] ?? "127.0.0.1"
        let echoMarker = env["SWIFTMOSH_REAL_E2E_ECHO_MARKER"] ?? "__SWIFTMOSH_ECHO__"

        let connect: MoshConnectInfo
        var launchedServerPID: pid_t?
        if let manualPort = env["SWIFTMOSH_REAL_E2E_PORT"],
           let manualKey = env["SWIFTMOSH_REAL_E2E_KEY"],
           let port = UInt16(manualPort)
        {
            connect = MoshConnectInfo(port: port, key: manualKey, serverPID: nil, serverOutput: nil)
        } else {
            connect = try Self.launchLocalMoshServer()
            launchedServerPID = connect.serverPID
        }

        var config = MoshClientConfig(maxReceiveStates: 2048, mtu: 1200)
        config.localPort = nil
        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: host, port: connect.port, keyBase64_22: connect.key),
            config: config
        )

        var stage = "start"
        do {
            stage = "session.start"
            try await session.start()
            stage = "session.enqueue/waitForHostBytes"
            let deadline = Date().addingTimeInterval(8)
            var echoBytes: String?
            while Date() < deadline {
                try await session.enqueue(.keystrokes(Data((echoMarker + "\n").utf8)))
                if let seen = try await waitForHostBytes(
                    session: session,
                    containing: echoMarker,
                    timeoutSeconds: 0.6,
                    throwOnTimeout: false
                ) {
                    echoBytes = seen
                    break
                }
                try await Task.sleep(nanoseconds: 80_000_000)
            }

            guard let echoBytes else {
                throw RealE2EError.timeoutWaitingForOutput(echoMarker)
            }
            XCTAssertTrue(echoBytes.contains(echoMarker), "Expected echo marker roundtrip via real server.")
        } catch {
            await session.stop()
            if let launchedServerPID {
                Self.terminateServerProcess(pid: launchedServerPID)
            }
            let serverOutput = connect.serverOutput?.outputString ?? "<no server output captured>"
            XCTFail(
                "Real E2E failed at stage '\(stage)' (host=\(host), port=\(connect.port), keyLen=\(connect.key.count)): \(error)\nServer output:\n\(serverOutput)"
            )
            throw error
        }

        await session.stop()
        if let launchedServerPID {
            Self.terminateServerProcess(pid: launchedServerPID)
        }
    }

    private func waitForHostBytes(
        session: MoshClientSession,
        containing needle: String,
        timeoutSeconds: TimeInterval,
        throwOnTimeout: Bool
    ) async throws -> String? {
        let start = Date()
        var aggregated = Data()
        let needleBytes = Data(needle.utf8)

        while Date().timeIntervalSince(start) < timeoutSeconds {
            let drained = await session.drainHostOps()
            for op in drained {
                if case .hostBytes(let bytes) = op {
                    aggregated.append(bytes)
                }
            }

            if aggregated.range(of: needleBytes) != nil {
                return String(decoding: aggregated, as: UTF8.self)
            }

            try await Task.sleep(nanoseconds: 20_000_000)
        }

        if throwOnTimeout {
            throw RealE2EError.timeoutWaitingForOutput(needle)
        }
        return nil
    }

    private static func launchLocalMoshServer() throws -> MoshConnectInfo {
        let env = ProcessInfo.processInfo.environment
        let binary = try resolveMoshServerPath(env: env)
        let bindAddress = env["SWIFTMOSH_REAL_E2E_BIND_ADDR"] ?? "127.0.0.1"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "new",
            "-i", bindAddress,
            "-p", "0",
            "--",
            "/bin/sh",
            "-lc",
            "exec cat"
        ]

        let combinedPipe = Pipe()
        let collector = OutputCollector()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe
        combinedPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data)
            }
        }

        try process.run()
        defer {
            combinedPipe.fileHandleForReading.readabilityHandler = nil
        }

        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if let connect = parseConnectInfo(from: collector.outputString) {
                return MoshConnectInfo(
                    port: connect.port,
                    key: connect.key,
                    serverPID: connect.serverPID,
                    serverOutput: collector
                )
            }

            if !process.isRunning {
                break
            }

            Thread.sleep(forTimeInterval: 0.02)
        }

        throw XCTSkip("Could not parse 'MOSH CONNECT' from mosh-server output: \(collector.outputString)")
    }

    private static func resolveMoshServerPath(env: [String: String]) throws -> String {
        if let override = env["MOSH_SERVER_BIN"], !override.isEmpty {
            return override
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "mosh-server"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XCTSkip("mosh-server not found. Install mosh or set MOSH_SERVER_BIN=/path/to/mosh-server.")
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw XCTSkip("mosh-server path lookup returned empty output.")
        }
        return path
    }

    private static func parseConnectInfo(from output: String) -> MoshConnectInfo? {
        let lines = output.split(whereSeparator: \.isNewline)
        var matchedPort: UInt16?
        var matchedKey: String?
        var matchedPID: pid_t?

        for line in lines {
            let lineString = String(line)
            if lineString.hasPrefix("MOSH CONNECT ") {
                let parts = lineString.split(separator: " ")
                if parts.count >= 4,
                   let port = UInt16(parts[2]),
                   parts[3].count == 22
                {
                    matchedPort = port
                    matchedKey = String(parts[3])
                }
            } else if lineString.contains("pid = ") {
                if let pidRange = lineString.range(of: "pid = ") {
                    let pidString = lineString[pidRange.upperBound...]
                        .prefix { $0.isNumber }
                    if let pid = Int32(pidString) {
                        matchedPID = pid
                    }
                }
            }
        }

        if let port = matchedPort, let key = matchedKey {
            return MoshConnectInfo(port: port, key: key, serverPID: matchedPID, serverOutput: nil)
        }
        return nil
    }

    private static func terminateServerProcess(pid: pid_t) {
        _ = kill(pid, SIGTERM)
    }

}

private struct MoshConnectInfo {
    let port: UInt16
    let key: String
    let serverPID: pid_t?
    let serverOutput: OutputCollector?
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var outputString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }
}

private enum RealE2EError: Error {
    case timeoutWaitingForOutput(String)
}

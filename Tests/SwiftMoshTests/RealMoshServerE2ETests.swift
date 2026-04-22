import Darwin
import Foundation
import XCTest
@testable import SwiftMosh

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
            connect = try Self.launchLocalMoshServer(environment: env)
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
            let serverOutput = connect.serverOutput ?? "<no server output captured>"
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

    private static func launchLocalMoshServer(environment: [String: String]) throws -> MoshConnectInfo {
        let bindAddress = environment["SWIFTMOSH_REAL_E2E_BIND_ADDR"] ?? "127.0.0.1"
        do {
            let connect = try MoshServerLauncher.launchLocalServer(
                bindAddress: bindAddress,
                timeout: 5,
                environment: environment,
                command: "exec cat"
            )
            return MoshConnectInfo(
                port: connect.port,
                key: connect.key,
                serverPID: connect.serverPID.map { pid_t($0) },
                serverOutput: connect.rawOutput
            )
        } catch MoshBootstrapError.missingServer {
            throw XCTSkip("mosh-server not found. Install mosh or set MOSH_SERVER_BIN=/path/to/mosh-server.")
        } catch {
            throw XCTSkip("Could not launch local mosh-server: \(error)")
        }
    }

    private static func terminateServerProcess(pid: pid_t) {
        _ = kill(pid, SIGTERM)
    }

}

private struct MoshConnectInfo {
    let port: UInt16
    let key: String
    let serverPID: pid_t?
    let serverOutput: String?
}

private enum RealE2EError: Error {
    case timeoutWaitingForOutput(String)
}

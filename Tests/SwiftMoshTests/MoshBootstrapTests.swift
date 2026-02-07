import Foundation
import XCTest
@testable import MoshBootstrap

final class MoshBootstrapTests: XCTestCase {
    func testParseNoisyOutputWithPID() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let output = """
        startup noise
        pid = 4242
        warning: still booting
        MOSH CONNECT 60001 \(key)
        trailing noise
        """

        let info = try MoshServerOutputParser.parse(output)
        XCTAssertEqual(info.port, 60001)
        XCTAssertEqual(info.key, key)
        XCTAssertEqual(info.serverPID, 4242)
    }

    func testParseSkipsMalformedConnectBeforeValidLine() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let output = """
        MOSH CONNECT badport badkey
        MOSH CONNECT 60002 \(key)
        """

        let info = try MoshServerOutputParser.parse(output)
        XCTAssertEqual(info.port, 60002)
        XCTAssertEqual(info.key, key)
    }

    func testParseMissingServerError() {
        assertBootstrapError(.missingServer) {
            _ = try MoshServerOutputParser.parse("mosh-server: command not found")
        }
    }

    func testParseMissingServerNotFoundErrorVariant() {
        assertBootstrapError(.missingServer) {
            _ = try MoshServerOutputParser.parse("mosh-server: not found")
        }
    }

    func testParseMissingServerNoSuchFileVariant() {
        assertBootstrapError(.missingServer) {
            _ = try MoshServerOutputParser.parse("mosh-server: No such file or directory")
        }
    }

    func testParseInvalidConnectLineError() {
        assertBootstrapError(.invalidConnectLine) {
            _ = try MoshServerOutputParser.parse("MOSH CONNECT")
        }
    }

    func testParseInvalidConnectTokenShape() {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        assertBootstrapError(.invalidConnectLine) {
            _ = try MoshServerOutputParser.parse("MOSH CONNECTX 60001 \(key)")
        }
    }

    func testParseInvalidPortError() {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        assertBootstrapError(.invalidPort) {
            _ = try MoshServerOutputParser.parse("MOSH CONNECT notaport \(key)")
        }
    }

    func testParseInvalidKeyError() {
        assertBootstrapError(.invalidKey) {
            _ = try MoshServerOutputParser.parse("MOSH CONNECT 60001 short")
        }
    }

    func testParsePermissionDeniedError() {
        assertBootstrapError(.permissionDenied) {
            _ = try MoshServerOutputParser.parse("mosh-server: Permission denied")
        }
    }

#if os(macOS)
    func testResolveServerPathWithoutOverrideUsesWhich() throws {
        let resolved = try MoshServerLauncher.resolveServerPath(environment: ProcessInfo.processInfo.environment)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testResolveServerPathWithoutOverrideMissingByPATH() {
        assertBootstrapError(.missingServer) {
            _ = try MoshServerLauncher.resolveServerPath(
                environment: ["PATH": "/definitely/not-a-real-bin-path"]
            )
        }
    }

    func testResolveServerPathWithoutOverrideEmptyLookupOutput() throws {
        let fakeWhich = try makeFile(
            name: "which",
            body: "#!/bin/sh\nexit 0\n",
            executable: true
        )
        defer { try? FileManager.default.removeItem(at: fakeWhich.deletingLastPathComponent()) }

        let pathOnly = fakeWhich.deletingLastPathComponent().path
        assertBootstrapError(.missingServer) {
            _ = try MoshServerLauncher.resolveServerPath(environment: ["PATH": pathOnly])
        }
    }

    func testResolveServerPathUsesOverrideBinary() throws {
        let script = try makeExecutableScript("exit 0")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let resolved = try MoshServerLauncher.resolveServerPath(
            environment: ["MOSH_SERVER_BIN": script.path]
        )
        XCTAssertEqual(resolved, script.path)
    }

    func testResolveServerPathMissingServerError() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        assertBootstrapError(.missingServer) {
            _ = try MoshServerLauncher.resolveServerPath(
                environment: ["MOSH_SERVER_BIN": missing.path]
            )
        }
    }

    func testResolveServerPathPermissionDeniedError() throws {
        let nonExecutable = try makeFile(
            name: "non-exec-server.sh",
            body: "#!/bin/sh\nexit 0\n",
            executable: false
        )
        defer { try? FileManager.default.removeItem(at: nonExecutable.deletingLastPathComponent()) }

        assertBootstrapError(.permissionDenied) {
            _ = try MoshServerLauncher.resolveServerPath(
                environment: ["MOSH_SERVER_BIN": nonExecutable.path]
            )
        }
    }

    func testLaunchLocalServerSuccessFromOverrideBinary() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let script = try makeExecutableScript("""
        echo "server warmup"
        echo "pid = 777"
        echo "MOSH CONNECT 62000 \(key)"
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let info = try MoshServerLauncher.launchLocalServer(
            timeout: 1,
            environment: ["MOSH_SERVER_BIN": script.path]
        )

        XCTAssertEqual(info.port, 62000)
        XCTAssertEqual(info.key, key)
        XCTAssertEqual(info.serverPID, 777)
        XCTAssertTrue(info.rawOutput.contains("MOSH CONNECT 62000 \(key)"))
    }

    func testLaunchLocalServerSuccessInjectsProcessPIDWhenMissing() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let script = try makeExecutableScript("""
        echo "MOSH CONNECT 62010 \(key)"
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let info = try MoshServerLauncher.launchLocalServer(
            timeout: 1,
            environment: ["MOSH_SERVER_BIN": script.path]
        )
        XCTAssertEqual(info.port, 62010)
        XCTAssertEqual(info.key, key)
        XCTAssertNotNil(info.serverPID)
    }

    func testLaunchLocalServerSuccessInjectsProcessPIDWhileRunning() throws {
        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        let script = try makeExecutableScript("""
        echo "MOSH CONNECT 62013 \(key)"
        sleep 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let info = try MoshServerLauncher.launchLocalServer(
            timeout: 1,
            environment: ["MOSH_SERVER_BIN": script.path]
        )
        XCTAssertEqual(info.port, 62013)
        XCTAssertEqual(info.key, key)
        XCTAssertNotNil(info.serverPID)
    }

    func testLaunchLocalServerInvalidKeyWhileRunning() throws {
        let script = try makeExecutableScript("""
        echo "MOSH CONNECT 62011 short"
        sleep 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        assertBootstrapError(.invalidKey) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 1,
                environment: ["MOSH_SERVER_BIN": script.path]
            )
        }
    }

    func testLaunchLocalServerPermissionDeniedWhileRunning() throws {
        let script = try makeExecutableScript("""
        echo "mosh-server: Permission denied"
        sleep 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        assertBootstrapError(.permissionDenied) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 1,
                environment: ["MOSH_SERVER_BIN": script.path]
            )
        }
    }

    func testLaunchLocalServerClassifiedFailureAfterExit() throws {
        let script = try makeExecutableScript("""
        echo "mosh-server: Permission denied"
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        assertBootstrapError(.permissionDenied) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 1,
                environment: ["MOSH_SERVER_BIN": script.path]
            )
        }
    }

    func testLaunchLocalServerConnectLineErrorAfterExit() throws {
        let script = try makeExecutableScript("""
        echo "MOSH CONNECT"
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        assertBootstrapError(.invalidConnectLine) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 1,
                environment: ["MOSH_SERVER_BIN": script.path]
            )
        }
    }

    func testLaunchLocalServerRunFailureMapsLaunchError() throws {
        let nonScript = try makeFile(
            name: "bad-exec",
            body: "not-a-script\n",
            executable: true
        )
        defer { try? FileManager.default.removeItem(at: nonScript.deletingLastPathComponent()) }

        assertBootstrapError(.processExited) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 1,
                environment: ["MOSH_SERVER_BIN": nonScript.path]
            )
        }
    }

    func testLaunchLocalServerProcessExitedError() throws {
        let script = try makeExecutableScript("""
        echo "starting"
        exit 2
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        assertBootstrapError(.processExited) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 1,
                environment: ["MOSH_SERVER_BIN": script.path]
            )
        }
    }

    func testLaunchLocalServerTimedOutError() throws {
        let script = try makeExecutableScript("""
        sleep 2
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        assertBootstrapError(.timedOut) {
            _ = try MoshServerLauncher.launchLocalServer(
                timeout: 0.1,
                environment: ["MOSH_SERVER_BIN": script.path]
            )
        }
    }

    func testRunProcessMissingExecutableMapsError() {
        assertBootstrapError(.processExited) {
            _ = try MoshServerLauncher.runProcess(executablePath: "/definitely/missing/exec", arguments: [])
        }
    }

    func testMapProcessLaunchErrorBranches() {
        struct Described: Error, CustomStringConvertible {
            let description: String
        }

        XCTAssertEqual(
            MoshServerLauncher.mapProcessLaunchError(Described(description: "Permission denied by policy")),
            .permissionDenied
        )
        XCTAssertEqual(
            MoshServerLauncher.mapProcessLaunchError(Described(description: "No such file or directory")),
            .missingServer
        )
        XCTAssertEqual(
            MoshServerLauncher.mapProcessLaunchError(Described(description: "something else")),
            .processExited
        )
    }

    func testConnectLineErrorUtility() {
        struct NotBootstrapError: Error {}

        let key = "ABCDEFGHIJKLMNOPQRSTUV"
        XCTAssertEqual(
            MoshServerLauncher.connectLineError(from: "MOSH CONNECT 62012 \(key)"),
            .processExited
        )
        XCTAssertEqual(
            MoshServerLauncher.connectLineError(from: "MOSH CONNECT"),
            .invalidConnectLine
        )
        XCTAssertEqual(
            MoshServerLauncher.connectLineError(
                from: "anything",
                parser: { _ in throw NotBootstrapError() }
            ),
            .processExited
        )
    }
#endif

    private func assertBootstrapError(
        _ expected: MoshBootstrapError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as MoshBootstrapError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

#if os(macOS)
    private func makeExecutableScript(_ body: String) throws -> URL {
        try makeFile(
            name: "fake-mosh-server.sh",
            body: """
            #!/bin/sh
            set -eu
            \(body)
            """,
            executable: true
        )
    }

    private func makeFile(
        name: String,
        body: String,
        executable: Bool
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mosh-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(name)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        let mode: Int = executable ? 0o755 : 0o644
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fileURL.path)
        return fileURL
    }
#endif
}

import Foundation

public struct MoshServerConnectInfo: Equatable, Sendable {
    public let port: UInt16
    public let key: String
    public let serverPID: Int32?
    public let rawOutput: String

    public init(port: UInt16, key: String, serverPID: Int32?, rawOutput: String) {
        self.port = port
        self.key = key
        self.serverPID = serverPID
        self.rawOutput = rawOutput
    }
}

public enum MoshBootstrapError: Error, Equatable, Sendable {
    case missingServer
    case invalidConnectLine
    case invalidPort
    case invalidKey
    case permissionDenied
    case processExited
    case timedOut
}

public enum MoshServerOutputParser {
    public static func parse(_ output: String) throws -> MoshServerConnectInfo {
        let normalizedOutput = output.replacingOccurrences(of: "\r\n", with: "\n")
        var firstConnectError: MoshBootstrapError?

        for rawLine in normalizedOutput.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ) {
            let line = String(rawLine)
            guard let markerRange = line.range(of: "MOSH CONNECT") else {
                continue
            }

            let connectLine = String(line[markerRange.lowerBound...])
            let fields = connectLine.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 4 else {
                firstConnectError = firstConnectError ?? .invalidConnectLine
                continue
            }
            guard fields[0] == "MOSH", fields[1] == "CONNECT" else {
                firstConnectError = firstConnectError ?? .invalidConnectLine
                continue
            }

            guard let port = UInt16(fields[2]), port > 0 else {
                firstConnectError = firstConnectError ?? .invalidPort
                continue
            }

            let key = String(fields[3])
            guard isValidMoshKey(key) else {
                firstConnectError = firstConnectError ?? .invalidKey
                continue
            }

            return MoshServerConnectInfo(
                port: port,
                key: key,
                serverPID: parsePID(from: normalizedOutput),
                rawOutput: normalizedOutput
            )
        }

        if let classified = classifyFailure(from: normalizedOutput) {
            throw classified
        }

        if let firstConnectError {
            throw firstConnectError
        }

        throw MoshBootstrapError.invalidConnectLine
    }

    static func classifyFailure(from output: String) -> MoshBootstrapError? {
        let lowercased = output.lowercased()

        if lowercased.contains("permission denied") {
            return .permissionDenied
        }

        if lowercased.contains("command not found") && lowercased.contains("mosh-server") {
            return .missingServer
        }

        let mentionsMoshServer = lowercased.contains("mosh-server")
        if mentionsMoshServer,
           (lowercased.contains("not found") || lowercased.contains("no such file or directory"))
        {
            return .missingServer
        }

        return nil
    }

    private static func parsePID(from output: String) -> Int32? {
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = pidRegex.firstMatch(in: output, options: [], range: range),
              let pidRange = Range(match.range(at: 1), in: output),
              let pid = Int32(output[pidRange])
        else {
            return nil
        }

        return pid
    }

    private static func isValidMoshKey(_ key: String) -> Bool {
        guard key.count == 22 else {
            return false
        }

        return key.unicodeScalars.allSatisfy { keyCharacterSet.contains($0) }
    }

    private static let pidRegex = try! NSRegularExpression(pattern: #"pid\s*=\s*([0-9]+)"#)
    private static let keyCharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_")
}

# swift-mosh

[![GitHub](https://img.shields.io/badge/-GitHub-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/wiedymi)
[![Twitter](https://img.shields.io/badge/-Twitter-1DA1F2?style=flat-square&logo=twitter&logoColor=white)](https://x.com/wiedymi)
[![Email](https://img.shields.io/badge/-Email-EA4335?style=flat-square&logo=gmail&logoColor=white)](mailto:contact@wiedymi.com)
[![Discord](https://img.shields.io/badge/-Discord-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/zemMZtrkSb)
[![Support me](https://img.shields.io/badge/-Support%20me-ff69b4?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/vivy-company)

Pure Swift implementation of the Mosh protocol/client stack for Apple platforms.

This library focuses on protocol + transport + crypto + state processing only.
Terminal UI/render adapters (Ghostty, SwiftUI terminal widgets, etc.) are intentionally out of scope so consumers can integrate with any renderer.

## Features

- Pure Swift Mosh protocol/client implementation
- Split modules for protocol layers:
  - `MoshCore`
  - `MoshTransport`
  - `MoshWire`
  - `MoshProtoLite`
  - `MoshCryptoOCB`
  - `MoshCompression`
  - `MoshBootstrap` (optional SSH handoff parser/helper)
- Real local `mosh-server` E2E test harness
- 100% automated test coverage across `Sources/` (via `./scripts/coverage.sh`)

## Platforms

- iOS 16+
- macOS 13+
- Swift tools 6.0+

## Installation

Add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wiedymi/swift-mosh", from: "0.1.0")
]
```

Then add products you need:

```swift
.target(
    name: "YourApp",
    dependencies: [
        "MoshCore"
    ]
)
```

## Quick start

```swift
import Foundation
import MoshCore

let endpoint = MoshEndpoint(
    host: "127.0.0.1",
    port: 60001,
    keyBase64_22: "REPLACE_WITH_MOSH_CONNECT_KEY"
)

let session = MoshClientSession(endpoint: endpoint)
try await session.start()

try await session.enqueue(.keystrokes(Data("echo hello from swift-mosh\n".utf8)))

// Streaming host output for your renderer.
for await op in await session.hostOpStream() {
    if case .hostBytes(let bytes) = op {
        print(String(decoding: bytes, as: UTF8.self), terminator: "")
    }
}

await session.stop()
```

Reliability/lifecycle knobs are configurable in `MoshClientConfig`:
- `sendMinDelayMs`
- `ackIntervalMs`
- `ackDelayMs`
- `networkTimeoutMs` (retained for snapshot/source compatibility; network silence does not end a Mosh session)
- `heartbeatIntervalMs`
- `initialRtoMs`
- `maxRtoMs`
- `maxRetransmitCount` (caps retry bookkeeping; unacknowledged state remains pending)

## Running tests

```bash
swift test
```

Coverage:

```bash
./scripts/coverage.sh
```

Run real local `mosh-server` E2E:

```bash
./scripts/run-real-e2e.sh
```

Or directly:

```bash
SWIFTMOSH_REAL_E2E=1 swift test --filter RealMoshServerE2ETests
```

## Optional Bootstrap Helper

`MoshBootstrap` can parse noisy `mosh-server` output and launch a local server:

```swift
import MoshBootstrap

let connect = try MoshServerLauncher.launchLocalServer()
// connect.port, connect.key, connect.serverPID
```

## Notes

- This package does not perform SSH negotiation itself.
  - You are expected to handle auth/session bootstrap externally, then pass `host`, UDP `port`, and 22-char key to `MoshEndpoint`.
- UI adapter is intentionally not included.
  - Consumers should map `MoshHostOp` to their own terminal backend/view layer.

## License

MIT

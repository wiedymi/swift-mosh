#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${SWIFTMOSH_REAL_E2E:-}" != "1" ]]; then
  export SWIFTMOSH_REAL_E2E=1
fi

swift test --filter RealMoshServerE2ETests

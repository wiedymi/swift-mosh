#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test --enable-code-coverage

PROFDATA="$(find .build -type f -name default.profdata | head -n 1)"
if [[ -z "${PROFDATA:-}" ]]; then
  echo "Could not locate coverage profile (.profdata)." >&2
  exit 1
fi

TEST_BINARY="$(find .build -type f | grep -E 'PackageTests.xctest/Contents/MacOS/.+PackageTests$' | head -n 1)"
if [[ -z "${TEST_BINARY:-}" ]]; then
  echo "Could not locate XCTest binary." >&2
  exit 1
fi

echo "\n== Coverage Summary =="
xcrun llvm-cov report "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex='(\.build|Tests)'

echo "\n== Coverage (Sources/) =="
xcrun llvm-cov report "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  Sources

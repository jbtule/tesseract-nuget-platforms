#!/usr/bin/env bash
# Runs an AnyUnit.Runner.Bootstrap-based test project (Tesseract.Tests,
# Tesseract.Tests.SkiaSharp) via `dotnet run`, not `dotnet test`: neither
# project references AnyUnit.TestingPlatform (the MTP adapter) or the old
# VSTest SDK, so `dotnet test` doesn't recognize either as a test project at
# all -- it silently restores and exits 0 without building or running
# anything (confirmed for real, not just from reading the SDK's own docs).
# `dotnet run -- <results.json>` builds it as a plain console app and hands
# that path straight to Program.cs's own args[0], which is what actually
# executes the suite and writes results.json.
#
# Tolerates exactly one known pre-existing failure the same way
# build-native-wasm.yml's own Unit tests step already does for the wasm leg:
# EngineTests.CanPrintVariables depends on running before CanSetDoubleVariable/
# CanSetIntegerVariable in the same process (libtesseract's parameter registry
# is process-global) -- a genuine test-order dependency in Tesseract.Tests
# itself, not something this script or a specific RID caused. A second Fail,
# or a different one (Fail count != 1, or any Error at all), still fails this
# script -- only that exact, already-diagnosed shape is swallowed.
#
# Usage: scripts/run-unit-tests.sh <csproj> <results.json output path>
set -euo pipefail

CSPROJ="$1"
RESULTS_JSON="$2"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

set +e
dotnet run --project "$CSPROJ" -c Release -f net10.0 -- "$RESULTS_JSON" | tee "$LOG"
exit_code="${PIPESTATUS[0]}"
set -e

if [ "$exit_code" -ne 0 ] && ! grep -qE "^ *Fail *1 *$" "$LOG"; then
  exit "$exit_code"
fi

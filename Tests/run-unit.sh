#!/bin/bash
# Unit tests: scanning, names, updates, backups, Steam, drives. A few seconds,
# no window, no network; every test works in its own throwaway folder and never
# touches the real library, settings or backups.
#   ./Tests/run-unit.sh                  # everything
#   ./Tests/run-unit.sh --filter Steam   # one suite or test
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"

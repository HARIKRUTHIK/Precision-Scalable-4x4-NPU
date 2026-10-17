#!/usr/bin/env bash
# Convenience wrapper around `make test` for CI or quick local runs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "error: iverilog not found. Install Icarus Verilog first." >&2
    echo "  Debian/Ubuntu: sudo apt-get install iverilog" >&2
    echo "  macOS:         brew install icarus-verilog" >&2
    exit 1
fi

make clean
make test "$@"

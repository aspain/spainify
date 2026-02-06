#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible entrypoint so README command `./setup.sh` works.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/setup.sh"

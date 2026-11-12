#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/build-sdk26.sh" "$@"

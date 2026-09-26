#!/bin/bash
# Compatibility entry point: macOS and Linux share the origin-only updater.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/auto-update.sh" "$@"
